{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Api.Internal.ImageManager
  ( saveAndInsertImages,
    DeleteStatus (..),
    deleteImagesArticle,
  )
where

import App
import Control.Monad (foldM, void, when)
import Control.Monad.Catch
import Control.Monad.Except (MonadTrans (lift), throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import DB.Scheme
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Function ((&))
import qualified Data.Text as T
import Data.Time (UTCTime (utctDay), getCurrentTime, toGregorian)
import Database.Esqueleto.Experimental
import qualified Database.Persist.Sql as P hiding ((==.))
import GHC.Generics (Generic)
import Katip (Severity (EmergencyS, ErrorS), katipAddContext, katipAddNamespace, logFM, sl)
import Katip.Monadic (logTM)
import Servant
import Servant.Multipart
import System.Directory (createDirectoryIfMissing, removeFile)

saveAndInsertImages :: [FileData Mem] -> (ImageId -> SqlPersistM ()) -> App [ImageId]
saveAndInsertImages fds inserter = do
  maxFiles <- askMaxImagesUpload
  when (length fds > maxFiles) (throwError err413 {errReasonPhrase = "Too many files, max file num is " ++ show maxFiles})
  maxFileSize <- askMaxImageSize
  mapM_
    ( \fd -> do
        when (T.takeWhile (/= '/') (fdFileCType fd) /= "image") (throwError err415) --not an image
        when (LBS.length (fdPayload fd) > maxFileSize) (throwError err413) --file too large
    )
    fds
  (year, month', day') <- liftIO $ toGregorian . utctDay <$> getCurrentTime
  imageRoot <- askImageRoot
  let trg = imageRoot ++ "/" ++ show year ++ "/" ++ show month' ++ "/" ++ show day'
  liftIO $ createDirectoryIfMissing True trg
  let insertDB =
        foldM
          ( \prev fd -> do
              [im] <- rawSqlInsertFileWithId trg fd
              inserter (entityKey im)
              return ((entityKey im, imagePath . entityVal $ im, fdPayload fd) : prev)
          )
          []
          fds
  runDB $ do
    fls <- insertDB
    liftIO $ onException (mapM (\(_, fp, bs) -> LBS.writeFile fp bs) fls) (mapM (\(_, fp, _) -> removeFile fp) fls)
    return $ map (\(imId, _, _) -> imId) fls

data DeleteException = DeleteException SomeException [ImageId] deriving (Show)

instance Exception DeleteException

data DeleteStatus = DeleteStatus
  { deleteStatus :: Bool,
    deleted :: [ImageId]
  }
  deriving (Show, Generic)

instance ToJSON DeleteStatus where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = camelTo2 '_'}

{- Safe deleting of images by the list of 'ImageId'.
  Function deletes both from DB and File storage.
  In case of failing upon deleting on of the images list of already deleted images is returned as well as false in 'DeleteStatus'.
  on success returnes true and a list of deleted images

-}
deleteImagesArticle :: [ImageId] -> ArticleId -> App DeleteStatus
deleteImagesArticle imagesToDelete aId = do
  artImages <- runDB $ do
    select $ do
      (im :& imArt) <-
        from $
          table @Image
            `innerJoin` table @ImageArticle
            `on` \(im :& imArticle) -> im ^. ImageId ==. imArticle ^. ImageArticleImageId
      where_ (imArt ^. ImageArticleArticleId ==. val aId)
      pure im
  handle handleDeleteException $
    DeleteStatus True
      <$> foldM
        ( \ims artImage ->
            if entityKey artImage `elem` imagesToDelete
              then deleteSafe artImage ims
              else return ims
        )
        []
        artImages
  where
    deleteSafe :: Entity Image -> [ImageId] -> App [ImageId]
    deleteSafe imageEnt ims = catch (deleteImage imageEnt >>= \imD -> return $ imD : ims) (ioExceptHandler ims)
    deleteImage imageEnt = runDB $ do
      P.delete (entityKey imageEnt)
      liftIO $ removeFile (imageEnt & entityVal & imagePath)
      return (entityKey imageEnt)
    ioExceptHandler :: (MonadThrow m) => [ImageId] -> SomeException -> m a
    ioExceptHandler ims = \se -> throwM $ DeleteException se ims
    handleDeleteException :: (MonadThrow m, MonadIO m) => DeleteException -> AppT m DeleteStatus
    handleDeleteException (DeleteException se ims) =
      katipAddContext (sl "delete_images" ims <> sl "deleting_error" (show se)) $ do
        logFM ErrorS "Not all of the requested images where deleted."
        return $ DeleteStatus False ims

--Query for saving image data to, generating filepath using newly optaioned image id
rawSqlInsertFileWithId :: (MonadIO m) => FilePath -> FileData Mem -> SqlPersistT m [Entity Image]
rawSqlInsertFileWithId root fd =
  P.rawSql
    " INSERT INTO image (path, mime) VALUES (? || currval('image_image_id_seq')|| ?, ?) RETURNING "
    [ P.PersistText $ T.pack root <> "/" <> "image",
      P.PersistText $ T.dropWhile (/= '.') (fdFileName fd),
      P.PersistText $ fdFileCType fd
    ]