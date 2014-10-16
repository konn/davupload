{-# LANGUAGE LambdaCase, NoMonomorphismRestriction, OverloadedStrings #-}
{-# LANGUAGE RankNTypes, RecordWildCards, TemplateHaskell             #-}
module Main where
import           Codec.Text.IConv                (Fuzzy (..), convertFuzzy)
import           Conduit                         hiding (yield)
import qualified Conduit                         as C
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBMQueue
import           Control.Exception.Lifted        hiding (catch)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch             (MonadCatch, catch)
import           Control.Monad.Loops             (iterateUntil, whileJust_)
import           Crypto.Conduit                  (sinkHash)
import qualified Data.ByteString.Char8           as BS
import qualified Data.ByteString.Lazy            as LBS
import           Data.Digest.Pure.MD5            (MD5Digest)
import           Data.List                       (intercalate)
import           Data.Monoid                     (mconcat)
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T
import           Filesystem                      (canonicalizePath, isDirectory)
import           Filesystem.Path                 (FilePath, splitDirectories,
                                                  stripPrefix)
import           Filesystem.Path.CurrentOS       (decodeString)
import           Filesystem.Path.Rules           (encode, posix)
import           Network.HTTP.Client             (BodyReader)
import           Network.HTTP.Client             (HttpException (..), brRead)
import           Network.HTTP.Client             (responseBody)
import           Network.HTTP.Conduit            (requestBodySourceChunked)
import           Network.HTTP.Types              (urlEncode)
import           Network.Protocol.HTTP.DAV
import           Options.Applicative
import           Prelude                         hiding (FilePath, readFile)
import           System.IO                       hiding (FilePath)

data Config = Config { fromPath :: FilePath
                     , toURL    :: String
                     , user     :: String
                     , passwd   :: String
                     , workers  :: Int
                     , encoding :: String
                     } deriving (Show, Eq, Ord)

runWorker :: Config -> TBMQueue FilePath -> IO ()
runWorker Config{..} tq = whileJust_ (atomically $ readTBMQueue tq) $ \fp ->
  handle (handler encoding fp) $ do
    let Just rel = stripPrefix fromPath fp
        dest = toURL ++ pathToURL encoding rel
    eith <- handle httpHandler $ evalDAVT dest $ do
      setCreds (BS.pack user) (BS.pack passwd)
      withContentM $ \rsp ->
        sourceReader (responseBody rsp) $$ sinkMD5
    let remoteMD5 = either (const Nothing) Just eith
    origMD5 <- runResourceT $ sourceFile fp $$ sinkMD5
    if remoteMD5 == Just origMD5
      then liftIO $ putStrLn $ "Skipping: " ++ encodeString encoding rel
      else do
      liftIO $ putStrLn $ "Copying: " ++ encodeString encoding rel ++ " to " ++ dest
      resl <- handle httpHandler $ evalDAVT dest $ do
        setCreds (BS.pack user) (BS.pack passwd)
        putContentM' (Nothing, requestBodySourceChunked $ sourceFile fp)
      either
        (\e -> hPutStrLn stderr $ "*** error during copying: " ++ encodeString encoding rel ++ ": " ++ e)
        return resl

encodeString :: String -> FilePath -> String
encodeString enc = T.unpack . T.decodeUtf8 . LBS.toStrict . convertFuzzy Transliterate enc "UTF-8" . LBS.fromChunks . pure .encode posix

httpHandler :: HttpException -> IO (Either String a)
httpHandler NoResponseDataReceived = return $ Left "Response data not recieved"
httpHandler exc = return . Left . show $ exc

pathToURL :: String -> FilePath -> String
pathToURL enc = intercalate "/" . map (BS.unpack . urlEncode True . T.encodeUtf8 . T.pack . encodeString enc) . splitDirectories

sinkMD5 :: Monad m => Sink BS.ByteString m MD5Digest
sinkMD5 = sinkHash

sourceReader :: MonadIO m => BodyReader -> Source m BS.ByteString
sourceReader br = void $ iterateUntil BS.null $ do
  ch <- liftIO $ brRead br
  C.yield ch
  return ch

handler :: String -> FilePath -> IOException -> IO ()
handler enc fp exc =
  hPutStrLn stderr $
  concat ["*** error: ", encodeString enc fp, ": ", show exc]

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
         <*> strOption (mconcat [long "encoding", short 'c'
                                  , metavar "ENCODING"
                                  , help "Original encoding name, recognizable by iconv (default: UTF-8)"
                                  , value "UTF-8" ])
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
puts s = putStr s >> hFlush stdout

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
  orig <- canonicalizePath $ if isDir && last (encodeString encoding fromPath) /= '/'
                             then decodeString (encodeString encoding fromPath ++ "/")
                             else fromPath
  let url'' | isDir && last url' /= '/' = url' ++ "/"
            | otherwise = url'
  let config' = c { user = user'
                  , passwd = passwd'
                  , fromPath = orig
                  , toURL = url''
                  }
  _ <- (runResourceT (sourceDir' config' orig
               $$ mapM_C (liftIO . atomically . writeTBMQueue ch))
    `finally` atomically (closeTBMQueue ch))
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
        eith <- liftIO $ handle httpHandler $ evalDAVT (toURL ++ pathToURL encoding rel) $ do
          setCreds (BS.pack user) (BS.pack passwd)
          mkCol `catch` \case
            StatusCodeException {} -> return False
            exc -> throwM exc
        either (\e -> liftIO $ hPutStrLn stderr $ "*** error creating: " ++ encodeString encoding rel ++ ": " ++ e)
               (const $ liftIO (putStrLn ("Directory created: " ++ encodeString encoding rel)) >> start ch) eith
        else C.yield ch

withEcho :: Bool -> IO b -> IO b
withEcho echo ac = do
  old <- hGetEcho stdin
  bracket_ (hSetEcho stdin echo) (hSetEcho stdin old >> putStrLn "") ac

