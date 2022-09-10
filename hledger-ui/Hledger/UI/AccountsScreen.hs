-- The accounts screen, showing accounts and balances like the CLI balance command.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module Hledger.UI.AccountsScreen
 (asNew
 ,asUpdate
 ,asDraw
 ,asDrawHelper
 ,asHandle
 ,handleHelpMode
 ,handleMinibufferMode
 ,asHandleNormalMode
 ,enterRegisterScreen
 ,asSetSelectedAccount
 )
where

import Brick
import Brick.Widgets.List
import Brick.Widgets.Edit
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Data.List hiding (reverse)
import Data.Maybe
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import qualified Data.Vector as V
import Data.Vector ((!?))
import Graphics.Vty (Event(..),Key(..),Modifier(..), Button (BLeft, BScrollDown, BScrollUp))
import Lens.Micro.Platform
import System.Console.ANSI
import System.FilePath (takeFileName)
import Text.DocLayout (realLength)

import Hledger
import Hledger.Cli hiding (Mode, mode, progname, prognameandversion)
import Hledger.UI.UIOptions
import Hledger.UI.UITypes
import Hledger.UI.UIState
import Hledger.UI.UIUtils
import Hledger.UI.UIScreens
import Hledger.UI.Editor
import Hledger.UI.ErrorScreen (uiReloadJournal, uiCheckBalanceAssertions, uiReloadJournalIfChanged)
import Hledger.UI.RegisterScreen (rsCenterSelection)
import Data.Either (fromRight)
import Control.Arrow ((>>>))


asDraw :: UIState -> [Widget Name]
asDraw ui = dlogUiTrace "asDraw 1" $ asDrawHelper ui ropts' scrname showbalchgkey
  where
    ropts' = _rsReportOpts $ reportspec_ $ uoCliOpts $ aopts ui
    scrname = "account " ++ if ishistorical then "balances" else "changes"
      where ishistorical = balanceaccum_ ropts' == Historical
    showbalchgkey = True

-- | Help draw any accounts-screen-like screen.
-- The provided ReportOpts are used instead of the ones in the UIState.
-- The other arguments are the screen display name and whether to show a key
-- for toggling between end balance and balance change mode.
asDrawHelper :: UIState -> ReportOpts -> String -> Bool -> [Widget Name]
asDrawHelper UIState{aopts=uopts, ajournal=j, aScreen=AS sst, aMode=mode} ropts scrname showbalchgkey =
  dlogUiTrace "asDraw 1" $
  case mode of
    Help       -> [helpDialog, maincontent]
    -- Minibuffer e -> [minibuffer e, maincontent]
    _          -> [maincontent]
  where
    UIOpts{uoCliOpts=copts} = uopts
    maincontent = Widget Greedy Greedy $ do
      c <- getContext
      let
        availwidth =
          -- ltrace "availwidth" $
          c^.availWidthL
          - 2 -- XXX due to margin ? shouldn't be necessary (cf UIUtils)
        displayitems = sst ^. assList . listElementsL

        acctwidths = V.map (\AccountsScreenItem{..} -> asItemIndentLevel + realLength asItemDisplayAccountName) displayitems
        balwidths  = V.map (maybe 0 (wbWidth . showMixedAmountB oneLine) . asItemMixedAmount) displayitems
        preferredacctwidth = V.maximum acctwidths
        totalacctwidthseen = V.sum acctwidths
        preferredbalwidth  = V.maximum balwidths
        totalbalwidthseen  = V.sum balwidths

        totalwidthseen = totalacctwidthseen + totalbalwidthseen
        shortfall = preferredacctwidth + preferredbalwidth + 2 - availwidth
        acctwidthproportion = fromIntegral totalacctwidthseen / fromIntegral totalwidthseen
        adjustedacctwidth = min preferredacctwidth . max 15 . round $ acctwidthproportion * fromIntegral (availwidth - 2)  -- leave 2 whitespace for padding
        adjustedbalwidth  = availwidth - 2 - adjustedacctwidth

        -- XXX how to minimise the balance column's jumping around as you change the depth limit ?

        colwidths | shortfall <= 0 = (preferredacctwidth, preferredbalwidth)
                  | otherwise      = (adjustedacctwidth, adjustedbalwidth)

      render $ defaultLayout toplabel bottomlabel $ renderList (asDrawItem colwidths) True (sst ^. assList)

      where
        ishistorical = balanceaccum_ ropts == Historical

        toplabel =
              withAttr (attrName "border" <> attrName "filename") files
          <+> toggles
          <+> str (" " ++ scrname)
          <+> borderPeriodStr (if ishistorical then "at end of" else "in") (period_ ropts)
          <+> borderQueryStr (T.unpack . T.unwords . map textQuoteIfNeeded $ querystring_ ropts)
          <+> borderDepthStr mdepth
          <+> str (" ("++curidx++"/"++totidx++")")
          <+> (if ignore_assertions_ . balancingopts_ $ inputopts_ copts
               then withAttr (attrName "border" <> attrName "query") (str " ignoring balance assertions")
               else str "")
          where
            files = case journalFilePaths j of
                           [] -> str ""
                           f:_ -> str $ takeFileName f
                           -- [f,_:[]] -> (withAttr ("border" <> "bold") $ str $ takeFileName f) <+> str " (& 1 included file)"
                           -- f:fs  -> (withAttr ("border" <> "bold") $ str $ takeFileName f) <+> str (" (& " ++ show (length fs) ++ " included files)")
            toggles = withAttr (attrName "border" <> attrName "query") $ str $ unwords $ concat [
               [""]
              ,if empty_ ropts then [] else ["nonzero"]
              ,uiShowStatus copts $ statuses_ ropts
              ,if real_ ropts then ["real"] else []
              ]
            mdepth = depth_ ropts
            curidx = case sst ^. assList . listSelectedL of
                       Nothing -> "-"
                       Just i -> show (i + 1)
            totidx = show $ V.length nonblanks
              where
                nonblanks = V.takeWhile (not . T.null . asItemAccountName) $ sst ^. assList . listElementsL

        bottomlabel = case mode of
                        Minibuffer label ed -> minibuffer label ed
                        _                   -> quickhelp
          where
            quickhelp = borderKeysStr' [
               ("?", str "help")
--              ,("RIGHT", str "register")
              ,("t", renderToggle (tree_ ropts) "list" "tree")
              -- ,("t", str "tree")
              -- ,("l", str "list")
              ,("-+", str "depth")
              ,(if showbalchgkey then "H" else "", renderToggle (not ishistorical) "end-bals" "changes")
              ,("F", renderToggle1 (isJust . forecast_ $ inputopts_ copts) "forecast")
              --,("/", "filter")
              --,("DEL", "unfilter")
              --,("ESC", "cancel/top")
              ,("a", str "add")
--               ,("g", "reload")
              ,("q", str "quit")
              ]
asDrawHelper _ _ _ _ = dlogUiTrace "asDrawHelper" $ errorWrongScreenType "draw function"  -- PARTIAL:

asDrawItem :: (Int,Int) -> Bool -> AccountsScreenItem -> Widget Name
asDrawItem (acctwidth, balwidth) selected AccountsScreenItem{..} =
  Widget Greedy Fixed $ do
    -- c <- getContext
      -- let showitem = intercalate "\n" . balanceReportItemAsText defreportopts fmt
    render $
      txt (fitText (Just acctwidth) (Just acctwidth) True True $ T.replicate (asItemIndentLevel) " " <> asItemDisplayAccountName) <+>
      txt balspace <+>
      splitAmounts balBuilder
      where
        balBuilder = maybe mempty showamt asItemMixedAmount
        showamt = showMixedAmountB oneLine{displayMinWidth=Just balwidth, displayMaxWidth=Just balwidth}
        balspace = T.replicate (2 + balwidth - wbWidth balBuilder) " "
        splitAmounts = foldr1 (<+>) . intersperse (str ", ") . map renderamt . T.splitOn ", " . wbToText
        renderamt :: T.Text -> Widget Name
        renderamt a | T.any (=='-') a = withAttr (sel $ attrName "list" <> attrName "balance" <> attrName "negative") $ txt a
                    | otherwise       = withAttr (sel $ attrName "list" <> attrName "balance" <> attrName "positive") $ txt a
        sel | selected  = (<> attrName "selected")
            | otherwise = id

asHandle :: BrickEvent Name AppEvent -> EventM Name UIState ()
asHandle ev = do
  ui0 <- get'
  dlogUiTraceM "asHandle"
  case ui0 of
    ui1@UIState{aMode=mode, aScreen=AS sst} -> case mode of
      Normal          -> asHandleNormalMode ui scr ev
      Minibuffer _ ed -> handleMinibufferMode ui ed ev
      Help            -> handleHelpMode ui ev
      where
        scr = AS
        -- save the currently selected account, in case we leave this screen and lose the selection
        selacct = case listSelectedElement $ _assList sst of
                    Just (_, AccountsScreenItem{..}) -> asItemAccountName
                    Nothing -> sst ^. assSelectedAccount
        ui = ui1{aScreen=scr sst{_assSelectedAccount=selacct}}
    _ -> dlogUiTraceM "asHandle" >> errorWrongScreenType "event handler"

-- | Handle events when in normal mode on any accounts-screen-like screen.
asHandleNormalMode :: UIState -> (AccountsScreenState -> Screen) -> BrickEvent Name AppEvent -> EventM Name UIState ()
asHandleNormalMode ui1@UIState{aopts=UIOpts{uoCliOpts=copts}, ajournal=j, aScreen=AS sst} scr ev = do
  d <- liftIO getCurrentDay
  let
    l = _assList sst
    centerSelection = scrollSelectionToMiddle l
    -- save the currently selected account, in case we leave this screen and lose the selection
    selacct = case listSelectedElement l of
                Just (_, AccountsScreenItem{..}) -> asItemAccountName
                Nothing -> sst ^. assSelectedAccount
    clickedAcctAt y =
      case asItemAccountName <$> listElements l !? y of
        Just t | not $ T.null t -> Just t
        _ -> Nothing
    ui = ui1{aScreen=AS sst{_assSelectedAccount=selacct}}
    nonblanks = V.takeWhile (not . T.null . asItemAccountName) $ listElements l
    lastnonblankidx = max 0 (length nonblanks - 1)
    journalspan = journalDateSpan False j

  case ev of

    VtyEvent (EvKey (KChar 'q') []) -> halt                               -- q: quit
    VtyEvent (EvKey (KChar 'z') [MCtrl]) -> suspend ui                    -- C-z: suspend
    VtyEvent (EvKey (KChar 'l') [MCtrl]) -> centerSelection >> redraw     -- C-l: redraw
    VtyEvent (EvKey KEsc        []) -> modify' (resetScreens d)           -- ESC: reset
    VtyEvent (EvKey (KChar c)   []) | c == '?' -> modify' (setMode Help)  -- ?: enter help mode

    -- App events: these do not come from the UI; they are received when --watch is used.
    -- XXX currently these are handled only in Normal mode
    -- XXX be sure we don't leave unconsumed app events piling up
    -- A data file has changed (or the user has pressed g): reload.
    e | e `elem` [AppEvent FileChange, VtyEvent (EvKey (KChar 'g') [])] -> liftIO (uiReloadJournal copts d ui) >>= put'
    -- The date has changed (and we are viewing a standard period which contained the old date):
    -- adjust the viewed period and regenerate, just in case needed.
    -- (Eg: when watching data for "today" and the time has just passed midnight.)
    AppEvent (DateChange old _) | isStandardPeriod p && p `periodContainsDate` old ->
      modify' (setReportPeriod (DayPeriod d) >>> regenerateScreens j d)
      where p = reportPeriod ui

    -- set or reset a filter:
    VtyEvent (EvKey (KChar '/') []) -> modify' (showMinibuffer "filter" Nothing >>> regenerateScreens j d)
    VtyEvent (EvKey k           []) | k `elem` [KBS, KDel] -> modify' (resetFilter >>> regenerateScreens j d)

    -- run external programs:
    VtyEvent (EvKey (KChar 'a') []) -> suspendAndResume $ clearScreen >> setCursorPosition 0 0 >> add copts j >> uiReloadJournalIfChanged copts d j ui
    VtyEvent (EvKey (KChar 'A') []) -> suspendAndResume $ void (runIadd (journalFilePath j)) >> uiReloadJournalIfChanged copts d j ui
    VtyEvent (EvKey (KChar 'E') []) -> suspendAndResume $ void (runEditor endPosition (journalFilePath j)) >> uiReloadJournalIfChanged copts d j ui

    -- adjust the period displayed:
    VtyEvent (EvKey (KChar 'T') []) ->       modify' (setReportPeriod (DayPeriod d)    >>> regenerateScreens j d)
    VtyEvent (EvKey (KDown)     [MShift]) -> modify' (shrinkReportPeriod d             >>> regenerateScreens j d)
    VtyEvent (EvKey (KUp)       [MShift]) -> modify' (growReportPeriod d               >>> regenerateScreens j d)
    VtyEvent (EvKey (KRight)    [MShift]) -> modify' (nextReportPeriod journalspan     >>> regenerateScreens j d)
    VtyEvent (EvKey (KLeft)     [MShift]) -> modify' (previousReportPeriod journalspan >>> regenerateScreens j d)

    -- various toggles and settings:
    VtyEvent (EvKey (KChar 'I') []) -> modify' (toggleIgnoreBalanceAssertions >>> uiCheckBalanceAssertions d)
    VtyEvent (EvKey (KChar 'F') []) -> modify' (toggleForecast d   >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar 'B') []) -> modify' (toggleConversionOp >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar 'V') []) -> modify' (toggleValue        >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '0') []) -> modify' (setDepth (Just 0)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '1') []) -> modify' (setDepth (Just 1)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '2') []) -> modify' (setDepth (Just 2)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '3') []) -> modify' (setDepth (Just 3)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '4') []) -> modify' (setDepth (Just 4)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '5') []) -> modify' (setDepth (Just 5)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '6') []) -> modify' (setDepth (Just 6)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '7') []) -> modify' (setDepth (Just 7)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '8') []) -> modify' (setDepth (Just 8)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar '9') []) -> modify' (setDepth (Just 9)  >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar c) []) | c `elem` ['-','_'] -> modify' (decDepth >>> regenerateScreens j d)
    VtyEvent (EvKey (KChar c) []) | c `elem` ['+','='] -> modify' (incDepth >>> regenerateScreens j d)
    -- toggles after which the selection should be recentered:
    VtyEvent (EvKey (KChar 'H') []) -> modify' (toggleHistorical   >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar 't') []) -> modify' (toggleTree         >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar 'R') []) -> modify' (toggleReal         >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar 'U') []) -> modify' (toggleUnmarked     >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar 'P') []) -> modify' (togglePending      >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar 'C') []) -> modify' (toggleCleared      >>> regenerateScreens j d) >> centerSelection
    VtyEvent (EvKey (KChar c) []) | c `elem` ['z','Z'] -> modify' (toggleEmpty >>> regenerateScreens j d) >> centerSelection  -- back compat: accept Z as well as z

    -- LEFT key or a click in the app's left margin: exit to the parent screen.
    VtyEvent e | e `elem` moveLeftEvents  -> modify' popScreen
    VtyEvent (EvMouseUp 0 _ (Just BLeft)) -> modify' popScreen  -- this mouse click is a VtyEvent since not in a clickable widget

    -- RIGHT key or MouseUp on an account: enter the register screen for the selected account
    VtyEvent e | e `elem` moveRightEvents, not $ isBlankItem $ listSelectedElement l -> enterRegisterScreen d selacct ui
    MouseUp _n (Just BLeft) Location{loc=(_,y)} | Just clkacct <- clickedAcctAt y    -> enterRegisterScreen d clkacct ui

    -- MouseDown: this is sometimes duplicated (https://github.com/jtdaugherty/brick/issues/347),
    -- so we use it only to move the selection.
    MouseDown _n BLeft _mods Location{loc=(_,y)} | not $ isBlankItem clickeditem ->
      put' ui{aScreen=scr sst}  -- XXX does this do anything ?
      where clickeditem = (0,) <$> listElements l !? y

    -- Mouse scroll wheel: scroll up or down to the maximum extent, pushing the selection when necessary.
    MouseDown name btn _mods _loc | btn `elem` [BScrollUp, BScrollDown] -> do
      let scrollamt = if btn==BScrollUp then -1 else 1
      l' <- nestEventM' l $ listScrollPushingSelection name (asListSize l) scrollamt
      put' ui{aScreen=scr sst{_assList=l'}}

    -- PGDOWN/END keys: handle with List's default handler, but restrict the selection to stop
    -- (and center) at the last non-blank item.
    VtyEvent e@(EvKey k []) | k `elem` [KPageDown, KEnd] -> do
      l1 <- nestEventM' l $ handleListEvent e
      if isBlankItem $ listSelectedElement l1
      then do
        let l2 = listMoveTo lastnonblankidx l1
        scrollSelectionToMiddle l2
        put' ui{aScreen=scr sst{_assList=l2}}
      else
        put' ui{aScreen=scr sst{_assList=l1}}

    -- DOWN key when selection is at the last item: scroll instead of moving, until maximally scrolled
    VtyEvent e | e `elem` moveDownEvents, isBlankItem mnextelement -> vScrollBy (viewportScroll $ l^.listNameL) 1
      where mnextelement = listSelectedElement $ listMoveDown l

    -- Any other vty event (UP, DOWN, PGUP etc): handle with List's default handler.
    VtyEvent e -> do
      l' <- nestEventM' l $ handleListEvent (normaliseMovementKeys e)
      put' ui{aScreen=scr $ sst & assList .~ l' & assSelectedAccount .~ selacct}

    -- Any other mouse/app event: ignore
    MouseDown{} -> return ()
    MouseUp{}   -> return ()
    AppEvent _  -> return ()

asHandleNormalMode _ _ _ = dlogUiTraceM "handleNormalMode" >> errorWrongScreenType "event handler"

-- | Handle events when in minibuffer mode on any screen.
handleMinibufferMode ui@UIState{ajournal=j} ed ev = do
  d <- liftIO getCurrentDay
  case ev of
    VtyEvent (EvKey KEsc   []) -> put' $ closeMinibuffer ui
    VtyEvent (EvKey KEnter []) -> put' $ regenerateScreens j d ui'
      where
        ui' = setFilter s (closeMinibuffer ui)
          & fromRight (showMinibuffer "Cannot compile regular expression" (Just s) ui)
          where s = chomp $ unlines $ map strip $ getEditContents ed
    VtyEvent (EvKey (KChar 'l') [MCtrl]) -> redraw
    VtyEvent (EvKey (KChar 'z') [MCtrl]) -> suspend ui
    VtyEvent e -> do
      ed' <- nestEventM' ed $ handleEditorEvent (VtyEvent e)
      put' ui{aMode=Minibuffer "filter" ed'}
    AppEvent _  -> return ()
    MouseDown{} -> return ()
    MouseUp{}   -> return ()

-- | Handle events when in help mode on any screen.
handleHelpMode ui ev =
  case ev of
    -- VtyEvent (EvKey (KChar 'q') []) -> halt
    VtyEvent (EvKey (KChar 'l') [MCtrl]) -> redraw
    VtyEvent (EvKey (KChar 'z') [MCtrl]) -> suspend ui
    _ -> helpHandle ev

enterRegisterScreen :: Day -> AccountName -> UIState -> EventM Name UIState ()
enterRegisterScreen d acct ui@UIState{ajournal=j, aopts=uopts} = do
  dlogUiTraceM "enterRegisterScreen"
  let
    regscr = rsNew uopts d j acct isdepthclipped
      where
        isdepthclipped = case getDepth ui of
                          Just de -> accountNameLevel acct >= de
                          Nothing -> False
    ui1 = pushScreen regscr ui
  rsCenterSelection ui1 >>= put'

-- | Set the selected account on an accounts screen. No effect on other screens.
asSetSelectedAccount :: AccountName -> Screen -> Screen
asSetSelectedAccount a (AS ass@ASS{}) = AS ass{_assSelectedAccount=a}
asSetSelectedAccount _ s = s

isBlankItem mitem = ((asItemAccountName . snd) <$> mitem) == Just ""

asListSize = V.length . V.takeWhile ((/="").asItemAccountName) . listElements



