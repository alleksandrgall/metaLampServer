{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module Auth where

import Crypto.KDF.BCrypt (validatePassword)
import DB.Scheme
import Data.Text (unpack)
import Data.Text.Encoding (decodeUtf8)
import Database.Persist.Sql
import Servant

checkBasicAuth :: (forall a. SqlPersistM a -> IO a) -> BasicAuthCheck User
checkBasicAuth runDB = BasicAuthCheck $ \BasicAuthData {..} -> runDB $ do
  u <- getBy . UniqueUserName . unpack . decodeUtf8 $ basicAuthUsername
  case u of
    Nothing -> return NoSuchUser
    Just ent -> do
      let valid = validatePassword basicAuthPassword (userPasswordHash . entityVal $ ent)
      if valid then return (Authorized $ entityVal ent) else return BadPassword