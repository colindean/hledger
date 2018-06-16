{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Handler.UploadR
  ( getUploadR
  , postUploadR
  ) where

import Import

import qualified Data.ByteString.Lazy as BL
import Data.Conduit (connect)
import Data.Conduit.Binary (sinkLbs)
import qualified Data.Text.Encoding as TE

import Widget.Common (fromFormSuccess, journalFile404, writeValidJournal)

uploadForm :: FilePath -> Markup -> MForm Handler (FormResult FileInfo, Widget)
uploadForm f =
  identifyForm "upload" $ \extra -> do
    (res, _) <- mreq fileField fs Nothing
    -- Ignoring the view - setting the name of the element is enough here
    pure (res, $(widgetFile "upload-form"))
  where
    fs = FieldSettings "file" Nothing (Just "file") (Just "file") []

getUploadR :: FilePath -> Handler ()
getUploadR = postUploadR

postUploadR :: FilePath -> Handler ()
postUploadR f = do
  VD {j} <- getViewData
  (f', _) <- journalFile404 f j
  ((res, view), enctype) <- runFormPost (uploadForm f')
  fi <- fromFormSuccess (showForm view enctype) res
  lbs <- BL.toStrict <$> connect (fileSource fi) sinkLbs

  -- Try to parse as UTF-8
  -- XXX Unfortunate - how to parse as system locale?
  text <- case TE.decodeUtf8' lbs of
    Left e -> do
      setMessage $
        "Encoding error: '" <> toHtml (show e) <> "'. " <>
        "If your file is not UTF-8 encoded, try the 'edit form', " <>
        "where the transcoding should be handled by the browser."
      showForm view enctype
    Right text -> return text
  writeValidJournal f text >>= \case
    Left e -> do
      setMessage $ "Failed to load journal: " <> toHtml e
      showForm view enctype
    Right () -> do
      setMessage $ "File " <> toHtml f <> " uploaded successfully"
      redirect JournalR
  where
    showForm view enctype =
      sendResponse <=< defaultLayout $ do
        setTitle "Upload journal"
        [whamlet|<form method=post enctype=#{enctype}>^{view}|]
