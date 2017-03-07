{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Web.Twitter.Conduit.Base
       ( getResponse
       , call
       , call'
       , callWithResponse
       , callWithResponse'
       , checkResponse
       , sourceWithMaxId
       , sourceWithMaxId'
       , sourceWithCursor
       , sourceWithCursor'
       , sourceWithSearchResult
       , sourceWithSearchResult'
       , endpoint
       , makeRequest
       , sinkJSON
       , sinkFromJSON
       ) where

import Web.Twitter.Conduit.Cursor
import Web.Twitter.Conduit.Parameters hiding (url)
import Web.Twitter.Conduit.Request
import Web.Twitter.Conduit.Response
import Web.Twitter.Conduit.Types
import Web.Twitter.Types.Lens

import Control.Lens
import Control.Monad.Base
import Control.Monad.Catch (MonadThrow (..))
import Control.Monad.Trans.Resource (MonadResource, ResourceT, runResourceT)
import Data.Aeson
import Data.Aeson.Lens
import Data.ByteString (ByteString)
import qualified Data.Conduit as C
import qualified Data.Conduit.Attoparsec as CA
import qualified Data.Conduit.List as CL
import qualified Data.Map as M
import Data.Monoid
import qualified Data.Text.Encoding as T
import Network.HTTP.Client.MultipartFormData
import qualified Network.HTTP.Conduit as HTTP
import qualified Network.HTTP.Types as HT
import Unsafe.Coerce
import Web.Authenticate.OAuth (signOAuth)

makeRequest :: APIRequest apiName responseType
            -> IO HTTP.Request
makeRequest (APIRequestGet u pa) = makeRequest' "GET" u (makeSimpleQuery pa)
makeRequest (APIRequestPost u pa) = makeRequest' "POST" u (makeSimpleQuery pa)
makeRequest (APIRequestPostMultipart u param prt) =
    formDataBody body =<< makeRequest' "POST" u []
  where
    body = prt ++ partParam
    partParam = Prelude.map (uncurry partBS . over _1 T.decodeUtf8) (makeSimpleQuery param)

makeRequest' :: HT.Method -- ^ HTTP request method (GET or POST)
             -> String -- ^ API Resource URL
             -> HT.SimpleQuery -- ^ Query
             -> IO HTTP.Request
makeRequest' m url query = do
    req <- HTTP.parseUrl url
    let addParams =
            if m == "POST"
            then HTTP.urlEncodedBody query
            else \r -> r { HTTP.queryString = HT.renderSimpleQuery False query }
    return $ addParams $ req { HTTP.method = m
                             , HTTP.checkStatus = \_ _ _ -> Nothing
                             }

getResponse :: MonadResource m
            => TWInfo
            -> HTTP.Manager
            -> HTTP.Request
            -> m (Response (C.ResumableSource m ByteString))
getResponse TWInfo{..} mgr req = do
    signedReq <- signOAuth (twOAuth twToken) (twCredential twToken) $ req { HTTP.proxy = twProxy }
    res <- HTTP.http signedReq mgr
    return
        Response { responseStatus = HTTP.responseStatus res
                 , responseHeaders = HTTP.responseHeaders res
                 , responseBody = HTTP.responseBody res
                 }

endpoint :: String
endpoint = "https://api.twitter.com/1.1/"

getValue :: Response (C.ResumableSource (ResourceT IO) ByteString)
         -> ResourceT IO (Response Value)
getValue res = do
    value <- responseBody res C.$$+- sinkJSON
    return $ res { responseBody = value }

checkResponse :: Response Value
              -> Either TwitterError Value
checkResponse Response{..} =
    case responseBody ^? key "errors" of
        Just errs@(Array _) ->
            case fromJSON errs of
                Success errList -> Left $ TwitterErrorResponse responseStatus responseHeaders errList
                Error msg -> Left $ FromJSONError msg
        Just err ->
            Left $ TwitterUnknownErrorResponse responseStatus responseHeaders err
        Nothing ->
            if sci < 200 || sci > 400
                then Left $ TwitterStatusError responseStatus responseHeaders responseBody
                else Right responseBody
  where
    sci = HT.statusCode responseStatus

getValueOrThrow :: FromJSON a
                => Response (C.ResumableSource (ResourceT IO) ByteString)
                -> ResourceT IO (Response a)
getValueOrThrow res = do
    res' <- getValue res
    case checkResponse res' of
        Left err -> throwM err
        Right _ -> return ()
    case fromJSON (responseBody res') of
        Success r -> return $ res' { responseBody = r }
        Error err -> throwM $ FromJSONError err

-- | Perform an 'APIRequest' and then provide the response which is mapped to a suitable type of
-- <http://hackage.haskell.org/package/twitter-types twitter-types>.
--
-- Example:
--
-- @
-- user <- 'call' twInfo mgr $ 'accountVerifyCredentials'
-- print user
-- @
--
-- If you need raw JSON value which is parsed by <http://hackage.haskell.org/package/aeson aeson>,
-- use 'call'' to obtain it.
call :: FromJSON responseType
     => TWInfo -- ^ Twitter Setting
     -> HTTP.Manager
     -> APIRequest apiName responseType
     -> IO responseType
call = call'

-- | Perform an 'APIRequest' and then provide the response.
-- The response of this function is not restrict to @responseType@,
-- so you can choose an arbitrarily type of FromJSON instances.
call' :: FromJSON value
      => TWInfo -- ^ Twitter Setting
      -> HTTP.Manager
      -> APIRequest apiName responseType
      -> IO value
call' info mgr req = responseBody `fmap` callWithResponse' info mgr req

-- | Perform an 'APIRequest' and then provide the 'Response'.
--
-- Example:
--
-- @
-- res \<- 'callWithResponse' twInfo mgr $ 'accountVerifyCredentials'
-- 'print' $ 'responseStatus' res
-- 'print' $ 'responseHeaders' res
-- 'print' $ 'responseBody' res
-- @
callWithResponse :: FromJSON responseType
                 => TWInfo -- ^ Twitter Setting
                 -> HTTP.Manager
                 -> APIRequest apiName responseType
                 -> IO (Response responseType)
callWithResponse = callWithResponse'

-- | Perform an 'APIRequest' and then provide the 'Response'.
-- The response of this function is not restrict to @responseType@,
-- so you can choose an arbitrarily type of FromJSON instances.
--
-- Example:
--
-- @
-- res \<- 'callWithResponse'' twInfo mgr $ 'accountVerifyCredentials'
-- 'print' $ 'responseStatus' res
-- 'print' $ 'responseHeaders' res
-- 'print' $ 'responseBody' (res :: Value)
-- @
callWithResponse' :: FromJSON value
                  => TWInfo
                  -> HTTP.Manager
                  -> APIRequest apiName responseType
                  -> IO (Response value)
callWithResponse' info mgr req =
    runResourceT $ do
        res <- getResponse info mgr =<< liftBase (makeRequest req)
        getValueOrThrow res

-- | A wrapper function to perform multiple API request with changing @max_id@ parameter.
--
-- This function cooperate with instances of 'HasMaxIdParam'.
sourceWithMaxId :: ( MonadBase IO m
                   , FromJSON responseType
                   , AsStatus responseType
                   , HasMaxIdParam (APIRequest apiName [responseType])
                   )
                => TWInfo -- ^ Twitter Setting
                -> HTTP.Manager
                -> APIRequest apiName [responseType]
                -> C.Source m responseType
sourceWithMaxId info mgr = loop
  where
    loop req = do
        res <- liftBase $ call info mgr req
        case getMinId res of
            Just mid -> do
                CL.sourceList res
                loop $ req & maxId ?~ mid - 1
            Nothing -> CL.sourceList res
    getMinId = minimumOf (traverse . status_id)

-- | A wrapper function to perform multiple API request with changing @max_id@ parameter.
-- The response of this function is not restrict to @responseType@,
-- so you can choose an arbitrarily type of FromJSON instances.
--
-- This function cooperate with instances of 'HasMaxIdParam'.
sourceWithMaxId' :: ( MonadBase IO m
                    ,  HasMaxIdParam (APIRequest apiName [responseType])
                    )
                 => TWInfo -- ^ Twitter Setting
                 -> HTTP.Manager
                 -> APIRequest apiName [responseType]
                 -> C.Source m Value
sourceWithMaxId' info mgr = loop
  where
    loop req = do
        res <- liftBase $ call' info mgr req
        case getMinId res of
            Just mid -> do
                CL.sourceList res
                loop $ req & maxId ?~ mid - 1
            Nothing -> CL.sourceList res
    getMinId = minimumOf (traverse . key "id" . _Integer)

-- | A wrapper function to perform multiple API request with changing @cursor@ parameter.
--
-- This function cooperate with instances of 'HasCursorParam'.
sourceWithCursor :: ( MonadBase IO m
                    , FromJSON responseType
                    , CursorKey ck
                    , HasCursorParam (APIRequest apiName (WithCursor ck responseType))
                    )
                 => TWInfo -- ^ Twitter Setting
                 -> HTTP.Manager
                 -> APIRequest apiName (WithCursor ck responseType)
                 -> C.Source m responseType
sourceWithCursor info mgr req = loop (-1)
  where
    loop 0 = CL.sourceNull
    loop cur = do
        res <- liftBase $ call info mgr $ req & cursor ?~ cur
        CL.sourceList $ contents res
        loop $ nextCursor res

-- | A wrapper function to perform multiple API request with changing @cursor@ parameter.
-- The response of this function is not restrict to @responseType@,
-- so you can choose an arbitrarily type of FromJSON instances.
--
-- This function cooperate with instances of 'HasCursorParam'.
sourceWithCursor' :: ( MonadBase IO m
                     , FromJSON responseType
                     , CursorKey ck
                     , HasCursorParam (APIRequest apiName (WithCursor ck responseType))
                     )
                  => TWInfo -- ^ Twitter Setting
                  -> HTTP.Manager
                  -> APIRequest apiName (WithCursor ck responseType)
                  -> C.Source m Value
sourceWithCursor' info mgr req = loop (-1)
  where
    relax :: FromJSON value
          => APIRequest apiName (WithCursor ck responseType)
          -> APIRequest apiName (WithCursor ck value)
    relax = unsafeCoerce
    loop 0 = CL.sourceNull
    loop cur = do
        res <- liftBase $ call info mgr $ relax $ req & cursor ?~ cur
        CL.sourceList $ contents res
        loop $ nextCursor res

-- | A wrapper function to perform multiple API request with @SearchResult@.
sourceWithSearchResult :: ( MonadBase IO m
                          , FromJSON responseType
                          , HasMaxIdParam (APIRequest apiName (SearchResult [responseType]))
                          )
                       => TWInfo -- ^ Twitter Setting
                       -> HTTP.Manager
                       -> APIRequest apiName (SearchResult [responseType])
                       -> m (SearchResult (C.Source m responseType))
sourceWithSearchResult info mgr req = do
    res <- liftBase $ call info mgr req
    let body = CL.sourceList (res ^. searchResultStatuses) <>
               loop (res ^. searchResultSearchMetadata . searchMetadataNextResults)
    return $ res & searchResultStatuses .~ body
  where
    origQueryMap = req ^. params . to M.fromList
    loop Nothing = CL.sourceNull
    loop (Just nextResultsStr) = do
        let nextResults = nextResultsStr & HT.parseSimpleQuery . T.encodeUtf8 & traversed . _2 %~ (PVString . T.decodeUtf8)
            nextParams = M.toList $ M.union (M.fromList nextResults) origQueryMap
        res <- liftBase $ call info mgr $ req & params .~ nextParams
        CL.sourceList (res ^. searchResultStatuses)
        loop $ res ^. searchResultSearchMetadata . searchMetadataNextResults

-- | A wrapper function to perform multiple API request with @SearchResult@.
sourceWithSearchResult' :: ( MonadBase IO m
                           , HasMaxIdParam (APIRequest apiName (SearchResult [responseType]))
                           )
                        => TWInfo -- ^ Twitter Setting
                        -> HTTP.Manager
                        -> APIRequest apiName (SearchResult [responseType])
                        -> m (SearchResult (C.Source m Value))
sourceWithSearchResult' info mgr req = do
    res <- liftBase $ call info mgr $ relax req
    let body = CL.sourceList (res ^. searchResultStatuses) <>
               loop (res ^. searchResultSearchMetadata . searchMetadataNextResults)
    return $ res & searchResultStatuses .~ body
  where
    origQueryMap = req ^. params . to M.fromList
    relax :: FromJSON value
          => APIRequest apiName (SearchResult responseType)
          -> APIRequest apiName (SearchResult value)
    relax = unsafeCoerce
    loop Nothing = CL.sourceNull
    loop (Just nextResultsStr) = do
        let nextResults = nextResultsStr & HT.parseSimpleQuery . T.encodeUtf8 & traversed . _2 %~ (PVString . T.decodeUtf8)
            nextParams = M.toList $ M.union (M.fromList nextResults) origQueryMap
        res <- liftBase $ call info mgr $ relax $ req & params .~ nextParams
        CL.sourceList (res ^. searchResultStatuses)
        loop $ res ^. searchResultSearchMetadata . searchMetadataNextResults

sinkJSON :: ( MonadThrow m
            ) => C.Consumer ByteString m Value
sinkJSON = CA.sinkParser json

sinkFromJSON :: ( FromJSON a
                , MonadThrow m
                ) => C.Consumer ByteString m a
sinkFromJSON = do
    v <- sinkJSON
    case fromJSON v of
        Error err -> throwM $ FromJSONError err
        Success r -> return r
