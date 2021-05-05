{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Unison.Server.CodebaseServer where

import Control.Applicative
import Control.Concurrent (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.Async (race)
import Control.Exception (ErrorCall (..), throwIO)
import Control.Lens
  ( (&),
    (.~),
  )
import Control.Monad (join)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson ()
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Lazy.UTF8 as BLU
import Data.Foldable (Foldable (toList))
import Data.Maybe (fromMaybe)
import Data.Monoid (Endo (..), appEndo)
import Data.OpenApi
  ( Info (..),
    License (..),
    OpenApi,
    URL (..),
  )
import qualified Data.OpenApi.Lens as OpenApi
import Data.Proxy (Proxy (..))
import Data.String (fromString)
import qualified Data.Text as Text
import GHC.Generics ()
import Network.HTTP.Media ((//), (/:))
import Network.HTTP.Types.Status (ok200)
import Network.Wai
  ( Request,
    queryString,
    responseLBS,
  )
import Network.Wai.Handler.Warp
  ( Port,
    defaultSettings,
    runSettings,
    setBeforeMainLoop,
    setHost,
    setPort,
    withApplicationSettings,
  )
import Options.Applicative
  ( auto,
    execParser,
    help,
    info,
    long,
    metavar,
    option,
    strOption,
  )
import Servant
  ( Header,
    MimeRender (..),
    addHeader,
    serveWithContext,
    throwError,
  )
import Servant.API
  ( Accept (..),
    Get,
    Headers,
    JSON,
    Raw,
    (:>),
    type (:<|>) (..),
  )
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Docs
  ( DocIntro (DocIntro),
    docsWithIntros,
    markdown,
  )
import Servant.OpenApi (HasOpenApi (toOpenApi))
import Servant.Server
  ( Application,
    Context (..),
    Handler,
    Server,
    ServerError (..),
    Tagged (Tagged),
    err401,
    err404,
  )
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )
import Servant.Server.StaticFiles (serveDirectoryWebApp)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath.Posix ((</>))
import System.Random.Stateful
  ( getStdGen,
    newAtomicGenM,
    uniformByteStringM,
  )
import Text.Read (readMaybe)
import Unison.Codebase (Codebase)
import Unison.Parser (Ann)
import Unison.Server.Endpoints.FuzzyFind
  ( FuzzyFindAPI,
    serveFuzzyFind,
  )
import Unison.Server.Endpoints.GetDefinitions
  ( DefinitionsAPI,
    serveDefinitions,
  )
import Unison.Server.Endpoints.ListNamespace
  ( NamespaceAPI,
    serveNamespace,
  )
import Unison.Server.Types (mungeString)
import Unison.Var (Var)

-- HTML content type
data HTML = HTML

newtype RawHtml = RawHtml { unRaw :: Lazy.ByteString }

instance Accept HTML where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender HTML RawHtml where
  mimeRender _ = unRaw

type OpenApiJSON = "openapi.json"
  :> Get '[JSON] (Headers '[Header "Access-Control-Allow-Origin" String] OpenApi)

type DocAPI = AuthProtect "token-auth" :> (UnisonAPI :<|> OpenApiJSON :<|> Raw)

type UnisonAPI = NamespaceAPI :<|> DefinitionsAPI :<|> FuzzyFindAPI

type instance AuthServerData (AuthProtect "token-auth") = ()

type WebUI = ("static" :> Raw) :<|> (AuthProtect "token-auth" :> Get '[HTML] RawHtml)

type ServerAPI = (("ui" :> WebUI) :<|> ("api" :> DocAPI))

genAuthServerContext
  :: Strict.ByteString -> Context (AuthHandler Request ()': '[])
genAuthServerContext token = authHandler token :. EmptyContext

authHandler :: Strict.ByteString -> AuthHandler Request ()
authHandler token = mkAuthHandler handler
 where
  throw401 msg = throwError $ err401 { errBody = msg }
  handler req =
    maybe (throw401 "Authentication token missing or incorrect")
          (const $ pure ())
      . lookup token
      $ queryString req

openAPI :: OpenApi
openAPI = toOpenApi api & OpenApi.info .~ infoObject

infoObject :: Info
infoObject = mempty
  { _infoTitle       = "Unison Codebase Manager API"
  , _infoDescription =
    Just "Provides operations for querying and manipulating a Unison codebase."
  , _infoLicense     = Just . License "MIT" . Just $ URL
                         "https://github.com/unisonweb/unison/blob/trunk/LICENSE"
  , _infoVersion     = "1.0"
  }

docsBS :: Lazy.ByteString
docsBS = mungeString . markdown $ docsWithIntros [intro] api
 where
  intro = DocIntro (Text.unpack $ _infoTitle infoObject)
                   (toList $ Text.unpack <$> _infoDescription infoObject)

docAPI :: Proxy DocAPI
docAPI = Proxy

api :: Proxy UnisonAPI
api = Proxy

serverAPI :: Proxy ServerAPI
serverAPI = Proxy

app
  :: Var v
  => Codebase IO v Ann
  -> Maybe FilePath
  -> Strict.ByteString
  -> Application
app codebase uiPath token =
  serveWithContext serverAPI (genAuthServerContext token)
    $ server codebase uiPath

genToken :: IO Strict.ByteString
genToken = do
  gen <- getStdGen
  g   <- newAtomicGenM gen
  Base64.encode <$> uniformByteStringM 24 g

data Waiter a
  = Waiter {
    notify :: a -> IO (),
    waitFor :: IO a
  }

mkWaiter :: IO (Waiter a)
mkWaiter = do
  mvar <- newEmptyMVar
  return Waiter {
    notify = putMVar mvar,
    waitFor = readMVar mvar
  }

ucmUIVar :: String
ucmUIVar = "UCM_WEB_UI"

ucmPortVar :: String
ucmPortVar = "UCM_PORT"

ucmHostVar :: String
ucmHostVar = "UCM_HOST"

ucmTokenVar :: String
ucmTokenVar = "UCM_TOKEN"

-- The auth token required for accessing the server is passed to the function k
start
  :: Var v => Codebase IO v Ann -> (Strict.ByteString -> Port -> IO ()) -> IO ()
start codebase k = do
  envToken <- lookupEnv ucmTokenVar
  envHost  <- lookupEnv ucmHostVar
  envPort  <- (readMaybe =<<) <$> lookupEnv ucmPortVar
  envUI    <- lookupEnv ucmUIVar
  let
    p =
      startServer codebase k
        <$> (   (<|> envToken)
            <$> (  optional
                .  strOption
                $  long "token"
                <> metavar "STRING"
                <> help "API auth token"
                )
            )
        <*> (   (<|> envHost)
            <$> (  optional
                .  strOption
                $  long "host"
                <> metavar "STRING"
                <> help "UCM server host"
                )
            )
        <*> (   (<|> envPort)
            <$> (  optional
                .  option auto
                $  long "port"
                <> metavar "NUMBER"
                <> help "UCM server port"
                )
            )
        <*> (   (<|> envUI)
            <$> (optional . strOption $ long "ui" <> metavar "DIR" <> help
                  "Path to codebase ui root"
                )
            )
  join . execParser $ info p mempty

startServer
  :: Var v
  => Codebase IO v Ann
  -> (Strict.ByteString -> Port -> IO ())
  -> Maybe String
  -> Maybe String
  -> Maybe Port
  -> Maybe String
  -> IO ()
startServer codebase k envToken envHost envPort envUI = do
  token <- case envToken of
    Just t -> return $ C8.pack t
    _      -> genToken
  let settings = appEndo
        (  foldMap (Endo . setPort)              envPort
        <> foldMap (Endo . setHost . fromString) envHost
        )
        defaultSettings
      a = app codebase envUI token
  case envPort of
    Nothing -> withApplicationSettings settings (pure a) (k token)
    Just p  -> do
      started <- mkWaiter
      let settings' = setBeforeMainLoop (notify started ()) settings
      result <- race (runSettings settings' a) (waitFor started *> k token p)
      case result of
        Left  () -> throwIO $ ErrorCall "Server exited unexpectedly!"
        Right x  -> pure x

serveIndex :: FilePath -> Handler RawHtml
serveIndex path = do
  let index = path </> "index.html"
  exists <- liftIO $ doesFileExist index
  if exists
    then fmap RawHtml . liftIO . Lazy.readFile $ path </> "index.html"
    else fail
 where
  fail = throwError $ err404
    { errBody =
      BLU.fromString
      $  "No codebase UI configured."
      <> " Set the "
      <> ucmUIVar
      <> " environment variable to the directory where the UI is installed."
    }

serveUI :: Maybe FilePath -> Server WebUI
serveUI p =
  let path = fromMaybe "ui" p
  in  serveDirectoryWebApp (path </> "static") :<|> (\_ -> serveIndex path)

server :: Var v => Codebase IO v Ann -> Maybe FilePath -> Server ServerAPI
server codebase uiPath =
  serveUI uiPath
    :<|> (\_ ->
           (    serveNamespace codebase
             :<|> serveDefinitions codebase
             :<|> serveFuzzyFind codebase
             )
             :<|> addHeader "*"
             <$>  serveOpenAPI
             :<|> Tagged serveDocs
         )
 where
  serveDocs _ respond = respond $ responseLBS ok200 [plain] docsBS
  serveOpenAPI = pure openAPI
  plain        = ("Content-Type", "text/plain")

