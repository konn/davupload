{-# LANGUAGE LambdaCase, NoMonomorphismRestriction, OverloadedStrings #-}
{-# LANGUAGE RankNTypes, RecordWildCards, TemplateHaskell             #-}
module Main where
import           Conduit                         hiding (yield)
import qualified Conduit                         as C
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBMQueue
import           Control.Exception               hiding (catch)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch             (MonadCatch, catch)
import           Control.Monad.Loops             (iterateUntil, whileJust_)
import           Crypto.Conduit                  (sinkHash)
import qualified Data.ByteString.Char8           as BS
import           Data.Digest.Pure.MD5            (MD5Digest)
import           Data.List                       (intercalate)
import           Data.Monoid                     (mconcat)
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T
import           Filesystem                      (canonicalizePath, isDirectory)
import           Filesystem.Path                 (splitDirectories, stripPrefix)
import           Filesystem.Path.CurrentOS       (FilePath, decodeString)
import           Filesystem.Path.CurrentOS       (encodeString)
import           Network.HTTP.Client             (BodyReader,
                                                  HttpException (..))
import           Network.HTTP.Client             (brRead, responseBody)
import           Network.HTTP.Conduit            (requestBodySourceChunked)
import           Network.HTTP.Types              (urlEncode)
import           Network.Protocol.HTTP.DAV
import           Options.Applicative
import           Prelude                         hiding (FilePath, readFile)
import           System.IO                       hiding (FilePath)
import           Text.XML                        hiding (readFile)
import           Text.XML.Cursor

data Config = Config { fromPath :: FilePath
                     , toURL    :: String
                     , user     :: String
                     , passwd   :: String
                     , workers  :: Int
                     } deriving (Show, Eq, Ord)

runWorker :: Config -> TBMQueue FilePath -> IO ()
runWorker Config{..} tq = whileJust_ (atomically $ readTBMQueue tq) $ \fp ->
  handle (handler fp) $ do
    let Just rel = stripPrefix fromPath fp
        dest = toURL ++ pathToURL rel
    eith <- handle httpHandler $ evalDAVT dest $ do
      setCreds (BS.pack user) (BS.pack passwd)
      withContentM $ \rsp ->
        sourceReader (responseBody rsp) $$ sinkMD5
    let remoteMD5 = either (const $ Nothing) Just eith
    origMD5 <- runResourceT $ sourceFile fp $$ sinkMD5
    if (remoteMD5 == Just origMD5)
      then liftIO $ putStrLn $ "Skipping: " ++ encodeString rel
      else do
      liftIO $ putStrLn $ "Copying: " ++ encodeString rel ++ " to " ++ dest
      resl <- handle httpHandler' $ evalDAVT dest $ do
        setCreds (BS.pack user) (BS.pack passwd)
        putContentM' (Nothing, requestBodySourceChunked $ sourceFile fp)
      either
        (\e -> hPutStrLn stderr $ "*** error during copying: " ++ encodeString rel ++ ": " ++ e)
        return resl

httpHandler :: HttpException -> IO (Either String MD5Digest)
httpHandler exc = return $ Left $ show exc

httpHandler' :: HttpException -> IO (Either String ())
httpHandler' = return . Left . show

pathToURL :: FilePath -> String
pathToURL = intercalate "/" . map (BS.unpack . urlEncode True . T.encodeUtf8 . T.pack . encodeString) . splitDirectories

sinkMD5 :: Monad m => Sink BS.ByteString m MD5Digest
sinkMD5 = sinkHash

sourceReader :: MonadIO m => BodyReader -> Source m BS.ByteString
sourceReader br = void $ iterateUntil BS.null $ do
  ch <- liftIO $ brRead br
  C.yield ch
  return ch

handler :: FilePath -> IOException -> IO ()
handler fp exc =
  hPutStrLn stderr $
  concat ["*** error: " ++ encodeString fp ++ ": " ++ show exc]

config :: Parser Config
config =
  Config <$> (decodeString <$>
              strOption (mconcat [long "from", short 'f'
                                 , metavar "PATH"
                                 , help "directory to upload"]))
         <*> strOption (mconcat [long "to", short 't'
                                , metavar "URI"
                                , help "distination", value ""
                                ])
         <*> strOption (mconcat [long "user", short 'u'
                                , metavar "USER"
                                , help "user name (default: empty)"
                                , value ""
                                ])
         <*> strOption (mconcat [long "pass", short 'p'
                                , metavar "PASS"
                                , help "password **Strongly recomended that you not use this*** (default: empty)"
                                , value ""
                                ])
         <*> option auto (mconcat [long "workers", short 'n'
                                  , metavar "NUM"
                                  , help "number of worker threads (default: 10)"
                                  , value 10  ])

configInfo :: ParserInfo Config
configInfo =
  info (helper <*> config) $
  mconcat [ fullDesc
            , progDesc "simple mirroring for webdav"
            , header "davupload - simple uploader for WebDAV"
            ]

data Entry = Directory FilePath
           | Normal FilePath
             deriving (Show, Eq, Ord)

makePrisms ''Entry

puts :: String -> IO ()
puts str = putStr str >> hFlush stdout

main :: IO ()
main = do
  c@Config{..} <- execParser configInfo
  url' <- if null toURL then puts "URL: " >> getLine else return toURL
  user' <- if null user
           then puts "USER: "  >> getLine
           else return user
  passwd' <- if null passwd
             then withEcho False (puts "PASS: " >> getLine)
             else return passwd
  ch <- newTBMQueueIO (workers * 20)
  isDir <- isDirectory fromPath
  orig <- canonicalizePath $ if isDir && last (encodeString fromPath) /= '/'
                             then decodeString (encodeString fromPath ++ "/")
                             else fromPath
  let url'' | isDir && last url' /= '/' = url' ++ "/"
            | otherwise = url'
  let config' = c { user = user'
                  , passwd = passwd'
                  , fromPath = orig
                  , toURL = url''
                  }
  _ <- ((runResourceT $ sourceDir' config' orig
               $$ mapM_C (liftIO . atomically . writeTBMQueue ch))
    `finally` do
      atomically (closeTBMQueue ch))
       `concurrently` mapConcurrently id (replicate workers $ runWorker config' ch)
  return ()

sourceDir' :: (MonadCatch m, MonadResource m) => Config -> FilePath -> Producer m FilePath
sourceDir' Config{..} = start
  where
    start :: (MonadCatch m, MonadResource m) => FilePath -> Producer m FilePath
    start dir = sourceDirectory dir =$= awaitForever go
    go ch = do
      isDir <- liftIO $ isDirectory ch
      if isDir
        then do
        let Just rel = stripPrefix fromPath ch
        eith <- evalDAVT (toURL ++ pathToURL rel) $ do
          setCreds (BS.pack user) (BS.pack passwd)
          mkCol `catch` \case
            StatusCodeException {} -> return False
            exc -> throwM exc
        either (\e -> liftIO $ hPutStrLn stderr $ "*** error: " ++ encodeString rel ++ ": " ++ e)
               (const $ liftIO (putStrLn ("Directory created: " ++ encodeString rel)) >> start ch) eith
        else C.yield ch

getResourceType :: MonadIO m => DAVT m T.Text
getResourceType = do
  depth0 <- use depth
  setDepth $ Just Depth0
  doc <- getPropsM
  let ans = fromDocument doc $// checkName (\name -> nameLocalName name == "resourcetype")
                             >=> child
  liftIO $ print $ fromDocument doc $// checkName (\name -> nameLocalName name == "resourcetype")
  let NodeElement el = node $ head ans
      kind = nameLocalName $ elementName el
  setDepth depth0
  return kind

getChildren :: MonadIO m => DAVT m [Entry]
getChildren = do
  depth0 <- use depth
  setDepth $ Just Depth1
  loc <- getDAVLocation
  doc <- getPropsM
  let chs = [ch | ch <- fromDocument doc $// checkName (\name -> nameLocalName name == "href")
                , all (/= T.pack loc) $ content =<< child ch]
  ans <- forM chs $ \ch -> do
        let typs = parent ch
                      >>= descendant
                      >>= checkName (\name -> nameLocalName name == "resourcetype")
                      >>= child
                      >>= checkName (\name -> nameLocalName name == "collection")
        return $ if not $ null typs
                 then Directory $ decodeString $ T.unpack $ T.concat $ child ch >>= content
                 else Normal $ decodeString $ T.unpack $ T.concat $ child ch >>= content
  setDepth depth0
  return ans


withEcho :: Bool -> IO b -> IO b
withEcho echo ac = do
  old <- hGetEcho stdin
  bracket_ (hSetEcho stdin echo) (hSetEcho stdin old >> putStrLn "") ac

