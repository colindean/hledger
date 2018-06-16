{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module Widget.AddForm
  ( addForm
  ) where

import Control.Monad.State.Strict (evalStateT)
import Data.Bifunctor (first)
import Data.List (dropWhileEnd, nub, sort, unfoldr)
import Data.Maybe (isJust)
import Data.Semigroup ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Text.Blaze.Internal (Markup, preEscapedString)
import Text.JSON
import Text.Megaparsec (eof, parseErrorPretty, runParser)
import Yesod

import Hledger
import Settings (widgetFile)

-- XXX <select> which journal to add to

addForm ::
     (site ~ HandlerSite m, RenderMessage site FormMessage, MonadHandler m)
  => Journal
  -> Day
  -> Markup
  -> MForm m (FormResult Transaction, WidgetFor site ())
addForm j today = identifyForm "add" $ \extra -> do
  (dateRes, dateView) <- mreq dateField dateFS Nothing
  (descRes, descView) <- mreq textField descFS Nothing
  (acctRes, _) <- mreq listField acctFS Nothing
  (amtRes, _) <- mreq listField amtFS Nothing

  let (msgs', postRes) = case validatePostings <$> acctRes <*> amtRes of
        FormSuccess (Left es) -> (es, FormFailure ["Postings validation failed"])
        FormSuccess (Right xs) -> ([], FormSuccess xs)
        FormMissing -> ([], FormMissing)
        FormFailure es -> ([], FormFailure es)
      msgs = zip [(1 :: Int)..] $ msgs' ++ replicate (4 - length msgs') ("", "", Nothing, Nothing)

  let descriptions = sort $ nub $ tdescription <$> jtxns j
      escapeJSSpecialChars = regexReplaceCI "</script>" "<\\/script>" -- #236
      listToJsonValueObjArrayStr = preEscapedString . escapeJSSpecialChars .
        encode . JSArray . fmap (\a -> JSObject $ toJSObject [("value", showJSON a)])
      journals = fst <$> jfiles j

  pure (makeTransaction <$> dateRes <*> descRes <*> postRes, $(widgetFile "add-form"))
  where
    makeTransaction date desc postings =
      nulltransaction {tdate = date, tdescription = desc, tpostings = postings}

    dateFS = FieldSettings "date" Nothing Nothing (Just "date")
      [("class", "form-control input-lg"), ("placeholder", "Date")]
    descFS = FieldSettings "desc" Nothing Nothing (Just "description")
      [("class", "form-control input-lg typeahead"), ("placeholder", "Description"), ("size", "40")]
    acctFS = FieldSettings "amount" Nothing Nothing (Just "account") []
    amtFS = FieldSettings "amount" Nothing Nothing (Just "amount") []
    dateField = checkMMap (pure . validateDate) (T.pack . show) textField
    validateDate s =
      first (const ("Invalid date format" :: Text)) $
      fixSmartDateStrEither' today (T.strip s)

    listField = Field
      { fieldParse = const . pure . Right . Just . dropWhileEnd T.null
      , fieldView = error "Don't render using this!"
      , fieldEnctype = UrlEncoded
      }

validatePostings :: [Text] -> [Text] -> Either [(Text, Text, Maybe Text, Maybe Text)] [Posting]
validatePostings a b =
  case traverse id $ (\(_, _, x) -> x) <$> postings of
    Left _ -> Left $ foldr catPostings [] postings
    Right [] -> Left
      [ ("", "", Just "Missing account", Just "Missing amount")
      , ("", "", Just "Missing account", Nothing)
      ]
    Right [p] -> Left
      [ (paccount p, T.pack . showMixedAmountWithoutPrice $ pamount p, Nothing, Nothing)
      , ("", "", Just "Missing account", Nothing)
      ]
    Right xs -> Right xs
  where
    postings = unfoldr go (True, a, b)

    go (_, x:xs, y:ys) = Just ((x, y, zipPosting (validateAccount x) (validateAmount y)), (True, xs, ys))
    go (True, x:y:xs, []) = Just ((x, "", zipPosting (validateAccount x) (Left "Missing amount")), (True, y:xs, []))
    go (True, x:xs, []) = Just ((x, "", zipPosting (validateAccount x) (Right missingamt)), (False, xs, []))
    go (False, x:xs, []) = Just ((x, "", zipPosting (validateAccount x) (Left "Missing amount")), (False, xs, []))
    go (_, [], y:ys) = Just (("", y, zipPosting (Left "Missing account") (validateAmount y)), (False, [], ys))
    go (_, [], []) = Nothing

    zipPosting = zipEither (\acc amt -> nullposting {paccount = acc, pamount = Mixed [amt]})

    catPostings (t, t', Left (e, e')) xs = (t, t', e, e') : xs
    catPostings (t, t', Right _) xs = (t, t', Nothing, Nothing) : xs

    errorToFormMsg = first (("Invalid value: " <>) . T.pack . parseErrorPretty)
    validateAccount = errorToFormMsg . runParser (accountnamep <* eof) "" . T.strip
    validateAmount = errorToFormMsg . runParser (evalStateT (amountp <* eof) mempty) "" . T.strip

-- Modification of Align, from the `these` package
zipEither :: (a -> a' -> r) -> Either e a -> Either e' a' -> Either (Maybe e, Maybe e') r
zipEither f a b = case (a, b) of
  (Right a', Right b') -> Right (f a' b')
  (Left a', Right _) -> Left (Just a', Nothing)
  (Right _, Left b') -> Left (Nothing, Just b')
  (Left a', Left b') -> Left (Just a', Just b')
