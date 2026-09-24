{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
-- KEEP THE PRAGMA BELOW: 'applyAttr' and 'applyTplAttr' must be TOTAL,
-- and a prop added to either GADT without its arm compiles, ships and
-- silently does nothing. -Wincomplete-patterns is not in GHC's default
-- set and this package sets no -Wall.
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- KEEP THIS ONE TOO: 'Declare' is how one name spans both zones, and a
-- method left out of ONE instance is a WARNING in GHC's default set —
-- it compiles, ships, and dies at the use site with "No instance
-- nor default method". That is exactly how 'collectionOf' could be
-- live-zone-only again (docs/deferred.md, the nested RECORD collection
-- entry).
{-# OPTIONS_GHC -Werror=missing-methods #-}

-- kaya's idiomatic surface for Haskell: scene declaration as a builder
-- monad, with When and For as combinators taking do-blocks. THE ZONE
-- RULE IS IN THE TYPES: Build's elements are Widgets, Tpl's are Nodes,
-- so `grep '-> Tpl Node'` is the template zone's whole surface — except
-- 'Declare', 'HandlerTarget' and 'CollectionHandle', which dispatch on a
-- SCOPE (tools/tpl-surfaces.py reads it both ways).
module KayaApp
  ( module Kaya.Core,
    Capabilities (..),
    capabilities,
    appDataDir,
    -- The formatter door and the catalog (docs\/compliance-plan.md §1.4).
    Length (..),
    NumberOptions (..),
    numberOptions,
    fmtDate,
    fmtDateWeekday,
    fmtTime,
    fmtDateTime,
    fmtNumber,
    fmtPercent,
    fmtCurrency,
    Locale (..),
    locale,
    Direction (..),
    direction,
    textScale,
    catalog,
    Arg,
    TrArg (..),
    tr,
    Prefs (..),
    prefs,
    kayaMain,
    newApp,
    post,
    buildTx,
    Ask,
    askAlert,
    askPickFiles,
    askPickFile,
    askSaveFile,
    askReadClipboard,
    build,
    runAsk,
    -- Exported for guests/haskell's AbortCheck, which reads a ranged
    -- format act's record back before it is submitted.
    stageTx,
    -- The document's own wire bytes, and the fold rule the live mirror
    -- and a stamped copy's ROW field share (docs\/rich-text-plan.md §19).
    -- Exported for guests/haskell's AbortCheck, which compares the bytes
    -- against the wire's rules and the two folds against each other.
    foldEdit,
    foldFormat,
    foldRowDocument,
    absorbEdit,
    submitTx,
    undoableTx,
    undoableTxIn,
    UndoDelta (..),
    UndoText (..),
    UndoEntry (..),
    UndoOrder (..),
    dispatch,
    HandlerTarget (..),
    -- `columns` rides 'Declare (..)' above: it stands in both zones.
    columnsAt,
    mount,
    mountIn,
    primary,
    createWindow,
    pushEntry,
    addSection,
    addSectionIn,
    selectSection,
    window,
    SectionAttr (..),
    Symbol (..),
    SectionsPresentation (..),
    Appearance (..),
    popEntry,
    EntryAttr (..),
    presentSheet,
    presentSheetOver,
    dismissSheet,
    SheetAttr (..),
    Detent (..),
    destroyWindow,
    WindowAttr (..),
    brandAccent,
    BrandAttr (..),
    brandTypeface,
    TypefaceAttr (..),
    appIdentity,
    Asset,
    asset,
    assetMissSentence,
    assetBytes,
    assetClose,
    Platform (..),
    AlertAttr (..),
    showAlert,
    NotificationAttr (..),
    showNotification,
    cancelNotification,
    onNotificationActivation,
    notificationResult,
    linkRoute,
    linkOpened,
    -- appPendingRoutes (the link-route check's own read of the parked
    -- declaration's bytes) now reaches guests through 'App (..)', moved
    -- to Kaya.Core with the record it is a field of.
    FileMode (..),
    openPicked,
    pickFiles,
    pickFile,
    saveFile,
    clearWidget,
    focusWidget,
    highlightRanges,
    selectRange,
    revealRange,
    scrollToRow,
    -- Rich text (docs\/rich-text-plan.md R1): the document, its edits and
    -- the widget's own acts.
    editSourceName,
    -- Exported for guests/haskell's AbortCheck, which is the only thing
    -- that reaches the wire mapping without a real keystroke.
    editSourceOfWire,
    Block (..),
    blockName,
    documentOf,
    mark,
    -- A run's mark is suffixed, the way `focusWidget` is: the plain names
    -- are the widget's own acts (docs\/rich-text-plan.md §18).
    boldRun,
    italicRun,
    underlineRun,
    strikeRun,
    codeRun,
    linkRun,
    blockRun,
    attrAt,
    insertEdit,
    deleteEdit,
    replaceEdit,
    markEdit,
    setRich,
    setOwnUndo,
    setSubmits,
    setDocument,
    applyEdit,
    formatText,
    -- The named acts (docs\/rich-text-plan.md §18).
    bold,
    italic,
    underline,
    strike,
    code,
    link,
    unformat,
    -- docs\/rich-text-plan.md §17: the ranged act, a document write
    -- beside the selection act.
    formatTextRange,
    unformatRange,
    setBlock,
    canUndo,
    canRedo,
    document,
    onEdit,
    onFormat,
    -- A stamped rich copy's own acts, with the row's key path first
    -- (docs\/rich-text-plan.md §19).
    onEditNode,
    onFormatNode,
    setText,
    bindText,
    bindA11yId,
    bindA11yLabel,
    bindA11yHint,
    bindHelp,
    bindPlaceholder,
    bindHref,
    bindChecked,
    bindValue,
    bindSource,
    setSpacing,
    setInset,
    setAlign,
    setAxis,
    stackWhen,
    columnsWhen,
    setA11yId,
    setA11yLabel,
    setA11yHint,
    setHelp,
    setPlaceholder,
    setHref,
    setRole,
    Align (..),
    Axis (..),
    SizeClass (..),
    Role (..),
    Attr (..),
    WClass (..),
    RowCol,
    LeafArgs,
    BothZones,
    BrandArgs,
    TypefaceArgs,
    row,
    column,
    scroll,
    grid,
    labeled,
    labeledBound,
    progress,
    progressIndeterminate,
    bindTextElement,
    -- Not a 'Declare' method (TypeApplications on a class method binds the
    -- class's own tyvar first — the idiom pass's F2): a top-level wrapper,
    -- standing in both zones, over the class's Proxy-taking
    -- 'collectionOfProxy' ('Declare (..)' still exports that one too; no
    -- guest should call it, @Note is the spelling).
    bindTextField,
    bindCheckedField,
    bindValueField,
    bindSourceField,
    bindDocumentField,
    button,
    buttonOn,
    entry,
    entryOn,
    textarea,
    textareaOn,
    search,
    searchOn,
    labelText,
    labelBound,
    headingText,
    headingBound,
    captionText,
    captionBound,
    checkboxOn,
    datePickerOn,
    datePickerBoundOn,
    timePickerOn,
    timePickerBoundOn,
    sliderOn,
    sliderBoundOn,
    selectOn,
    radioOn,
    spacer,
    imageBytes,
    imageAsset,
    imageBound,
    Paint (..),
    FillRule (..),
    TextAlign (..),
    TextBaseline (..),
    moveTo,
    lineTo,
    close,
    polyline,
    stroke,
    fill,
    font,
    text,
    canvas,
    canvasOf,
    drawAt,
    -- The size policy, LIVE CANVASES ONLY (docs/canvas-plan.md §3.2.1);
    -- `scale` is spelled by writing none of these three.
    fixed,
    onDraw,
    onTick,
    TplStrSource,
    bindTextSource,
    TplBoolSource (..),
    TplDateSource (..),
    TplTimeSource (..),
    TplNumberSource (..),
    TplImageSource (..),
    TplAttr (..),
    withTplAttrs,
    label,
    heading,
    caption,
    checkbox,
    datePicker,
    timePicker,
    bindDateField,
    bindTimeField,
    image,
    rowOf,
    columnOf,
    scrollOf,
    gridOf,
    labeledOf,
    buttonBound,
    entryBound,
    textareaBound,
    textareaRichBound,
    searchBound,
    progressBound,
    slider,
    select,
    radio,
    MScope (..),
    MItem,
    MOption,
    Catalog,
    IAttr (..),
    item,
    toggle,
    option,
    separator,
    menu,
    radioGroup,
    contextMenu,
    contextCatalog,
    nodeContextMenu,
    setMenuLabel,
    bindMenuLabel,
    setMenuEnabled,
    bindMenuEnabled,
    setMenuChecked,
    bindMenuChecked,
    setMenuValue,
    bindMenuValue,
    setMenuIcon,
    setMenuSymbol,
    setMenuPrimary,
    setMenuShortcut,
    setMenuRole,
    copy,
    emptyClip,
    Clip (..),
    emptyTplClip,
    TplClip (..),
    TplRep (..),
    readClipboard,
    setAccepts,
    -- `onPaste` rides 'HandlerTarget (..)' above: it stands in both zones.
    setDragSource,
    setDropTarget,
    setDragSourceAt,
    setDropTargetAt,
    setNodeDragSource,
    setNodeDropTarget,
    setReorderable,
    -- `onDrop`/`onDragEnded` ride 'HandlerTarget (..)' above, 'onPaste''s
    -- shape.
    acceptText,
    acceptHtml,
    acceptImage,
    acceptFiles,
    roleSettings,
    roleCut,
    roleCopy,
    rolePaste,
    roleUndo,
    roleRedo,
    menuAppend,
    menuOptions,
  )
where


import Control.Concurrent (ThreadId, forkIO, myThreadId, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (modifyMVar, modifyMVar_, newMVar)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder)
import Data.Int (Int32, Int64)
import Data.IORef
import Data.List (elemIndex)
import Data.Maybe (fromMaybe, listToMaybe)
import GHC.TypeLits (ErrorMessage (..), TypeError)
import qualified Data.Map.Strict as Map
import qualified Data.List as List
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import Data.Word (Word32, Word64)
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import Control.Exception (SomeException, catch, evaluate)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import KayaRuntime
  ( UndoDelta (..),
    UndoText (..),
    UndoEntry (..),
    UndoOrder (..),
    emptyUndoDelta,
    kayaRun,
    kayaSubmit,
    pollOccurrence,
    registerBlob,
    wake,
    waitOccurrences,
  )
import qualified KayaRuntime as R
import System.IO (Handle)
import qualified KayaWire as W
import Control.Monad.State.Strict (gets, runState, state)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Cont (ContT (..), evalContT)
import Control.Monad.Trans.Reader (ReaderT (..))
import qualified Control.Monad.Trans.Reader as Reader
import Kaya.Core

-- | WHAT THIS HOST CAN DO — see crates/kaya/src/app.rs for the
-- canonical note, which every binding's copy of this surface shortens.
data Capabilities = Capabilities
  { -- | The host can materialize a surface beside the primary one
    -- ('createWindow', 'mountIn'). 'False' on iOS and Android.
    auxWindows :: Bool,
    -- | This process can post a local notification the desktop will
    -- show (docs/tasks-s3-plan.md N3). A RUNTIME bit: the host measures
    -- it at startup.
    notifications :: Bool
  }
  deriving (Eq, Show)

-- | This host's capabilities. Constant for the life of the process, so
-- asking once and remembering is fine.
capabilities :: IO Capabilities
capabilities = do
  bits <- R.capabilityBits
  pure
    ( Capabilities
        ((bits .&. R.capAuxWindows) /= 0)
        ((bits .&. R.capNotifications) /= 0)
    )

-- | The notification_result decision, in a function of its own because
-- the ring loop's branch has no seam a test can reach (the ring is C
-- memory) — Go's @notificationResult@ for the same reason, and
-- guests\/haskell's @kaya-notify-order-check@ drives the three cases
-- through here. THE ORDER IS THE SEMANTICS (docs\/tasks-s9-plan.md R1)
-- and tools\/check-sugar-surface.py reads it out of this body: the
-- one-shot handler bound at the show first, retiring with the result;
-- else the process-level one, which does not; else the drop is
-- announced.
notificationResult :: App -> Word64 -> Word32 -> IO ()
notificationResult app ident wire = do
  handlers <- readIORef (app.appNotificationHandlers)
  writeIORef (app.appNotificationHandlers) (Map.delete ident handlers)
  activation <- readIORef (app.appNotificationActivation)
  -- The RING's own word here, the app's typed outcome from here on.
  let outcome = notificationOutcomeOfWire wire
  case (Map.lookup ident handlers, activation) of
    (Just handler, _) -> dispatch (handler outcome)
    (Nothing, Just act) -> dispatch (act ident outcome)
    (Nothing, Nothing) -> do
      let word = case outcome of
            NotificationActivated -> "activated"
            NotificationRefused -> "refused"
      hPutStrLn
        stderr
        ( "kaya: notification "
            ++ show ident
            ++ " outcome "
            ++ word
            ++ " reached no handler — none was bound at the show and no"
            ++ " process-level handler is registered"
            ++ " (KayaApp.onNotificationActivation)"
        )

-- | The app's OWN writable directory (docs/tasks-s4-plan.md P1):
-- Application Support\/\<id\> on macOS, Documents on iOS, the files
-- directory on Android, @$XDG_DATA_HOME\/\<id\>@ on Linux,
-- @%LOCALAPPDATA%\\\<id\>@ on Windows. Created on first ask.
--
-- KAYA OWNS THE PLACE AND NOTHING ELSE: the app's document is the app's,
-- written the standard way. Settings are small and typed and belong in
-- 'prefs'.
--
-- RAISES where the platform has handed no directory over — an error
-- state a guest cannot plan around, so all nine bindings refuse rather
-- than answering an absent value (ruled 2026-09-09).
-- A 'FilePath' and not 'Text', deliberately: this is a place to build
-- paths under, and @(\<\/\>)@, @createDirectoryIfMissing@ and @openFile@
-- all take one.
-- | How much of a date or time to write: the numeric form, the
-- abbreviated words, the full words.
data Length = Short | Medium | Long deriving (Eq, Show)

lengthCode :: Length -> Int64
lengthCode Short = 0
lengthCode Medium = 1
lengthCode Long = 2

-- | What a number formatter may be told; 'Nothing' is the platform's own
-- default, 'numberOptions' the record that states nothing.
data NumberOptions = NumberOptions
  { minFractionDigits :: Maybe Int,
    maxFractionDigits :: Maybe Int,
    grouping :: Bool
  }
  deriving (Eq, Show)

numberOptions :: NumberOptions
numberOptions = NumberOptions Nothing Nothing True

-- A fault at the floor is raised BY NAME, never an empty string.
door :: String -> IO (Maybe Text) -> IO Text
door name ask = ask >>= maybe (ioError (userError ("kaya: " ++ name ++ " reported a fault (the sentence is on stderr)"))) return

digitsOf :: Maybe Int -> Int32
digitsOf = maybe (-1) fromIntegral

-- | The date at a length, in the process locale (the door's Apple,
-- glibc, android.icu or Windows.Globalization arm).
fmtDate :: Length -> Day -> IO Text
fmtDate len day = door "kaya_fmt_date" (R.fmtDateRaw (packDay day) (lengthCode len))

-- | The date with its weekday and no year, the task list's idiom.
fmtDateWeekday :: Day -> IO Text
fmtDateWeekday day = door "kaya_fmt_date_weekday" (R.fmtDateWeekdayRaw (packDay day))

fmtTime :: Length -> TimeOfDay -> IO Text
fmtTime len t = door "kaya_fmt_time" (R.fmtTimeRaw (packTimeOfDay t) (lengthCode len))

fmtDateTime :: Length -> Day -> TimeOfDay -> IO Text
fmtDateTime len day t =
  door "kaya_fmt_date_time" (R.fmtDateTimeRaw (packDay day) (packTimeOfDay t) (lengthCode len))

fmtNumber :: NumberOptions -> Double -> IO Text
fmtNumber o v =
  door "kaya_fmt_number" (R.fmtNumberRaw v (digitsOf o.minFractionDigits) (digitsOf o.maxFractionDigits) o.grouping)

fmtPercent :: NumberOptions -> Double -> IO Text
fmtPercent o v =
  door "kaya_fmt_percent" (R.fmtPercentRaw v (digitsOf o.minFractionDigits) (digitsOf o.maxFractionDigits) o.grouping)

-- | @fmtCurrency 12.5 "USD"@: the ISO 4217 code.
fmtCurrency :: Double -> Text -> IO Text
fmtCurrency v code = door "kaya_fmt_currency" (R.fmtCurrencyRaw v code)

-- | Who the user is: the BCP-47 tag, the hour cycle (12 or 24), the first
-- weekday (1 Monday .. 7 Sunday), the calendar and the numbering system.
data Locale = Locale
  { localeTag :: Text,
    localeHourCycle :: Int,
    localeFirstWeekday :: Int,
    localeCalendar :: Text,
    localeNumbering :: Text
  }
  deriving (Eq, Show)

locale :: IO Locale
locale = do
  line <- door "kaya_locale" R.localeLine
  case T.words line of
    [tag, cycle, first, cal, num] ->
      return (Locale tag (read (T.unpack cycle)) (read (T.unpack first)) cal num)
    _ -> ioError (userError "kaya: kaya_locale answered a line this binding cannot read")

data Direction = Ltr | Rtl deriving (Eq, Show)

direction :: IO Direction
direction = (\bit -> if bit == 1 then Rtl else Ltr) <$> R.directionBit

textScale :: IO Double
textScale = R.textScaleRaw

-- | @catalog "tasks"@ loads l10n\/tasks.<locale>.ftl under the asset root
-- once at startup (docs\/compliance-plan.md §2.4).
catalog :: Text -> IO ()
catalog = R.catalogRaw

-- | One argument to 'tr': an int, a float, a string, a 'Day' or a
-- 'TimeOfDay', written @arg x@ so the list reads as one shape.
type Arg = R.TrArgRaw

class TrArg a where
  arg :: a -> Arg

instance TrArg Int where arg = R.TrInt . fromIntegral

instance TrArg Integer where arg = R.TrInt . fromIntegral

instance TrArg Int64 where arg = R.TrInt

instance TrArg Double where arg = R.TrFloat

instance TrArg Text where arg = R.TrStr

instance TrArg Day where arg = R.TrDate . packDay

instance TrArg TimeOfDay where arg = R.TrTime . packTimeOfDay

-- | The message with its arguments filled, dates and numbers through the
-- door; a missing key or argument is the core's panic naming it.
tr :: Text -> [(Text, Arg)] -> IO Text
tr key args = door "kaya_tr" (R.trRaw key args)

appDataDir :: IO FilePath
appDataDir = do
  dir <- R.appDataDir
  if null dir
    then
      errorWithoutStackTrace
        ( "kaya: app_data_dir asked before the platform handed one over"
            ++ " (Android before attach)"
        )
    else return dir

-- | The app's preferences store (docs\/tasks-s4-plan.md P2\/P3): a small
-- typed key-value record under the app's id, the platform's own where
-- the platform has one — UserDefaults on Apple, SharedPreferences on
-- Android, a key file on Linux and Windows.
--
-- A PULL, NOT A SIGNAL: a setting is read when the app builds and
-- written when the user changes it. Every getter takes the default it
-- answers when the key is absent OR holds another type. Writes are
-- durable when they return, and the store may be used from any thread.
-- THE FIELDS CARRY THE `pref` PREFIX, a language flavor and not a
-- divergence: this module already exports a collection `remove`, and
-- Haskell record fields are top-level selectors.
data Prefs = Prefs
  { prefGetString :: Text -> Text -> IO Text,
    prefGetI64 :: Text -> Int64 -> IO Int64,
    prefGetF64 :: Text -> Double -> IO Double,
    prefGetBool :: Text -> Bool -> IO Bool,
    prefSetString :: Text -> Text -> IO (),
    prefSetI64 :: Text -> Int64 -> IO (),
    prefSetF64 :: Text -> Double -> IO (),
    prefSetBool :: Text -> Bool -> IO (),
    prefRemove :: Text -> IO ()
  }

-- A guest may READ any key and WRITE any key kaya has not reserved
-- (docs/tasks-s4-plan.md P4: window memory lives under @kaya.@).
prefKey :: Text -> Text
prefKey key
  | T.null key = errorWithoutStackTrace "kaya: a preference key must not be empty"
  | otherwise = key

prefWriteKey :: Text -> Text
prefWriteKey key
  -- The refusal's own sentence is byte-compared across the nine
  -- bindings (tools/check-sugar-surface.py), so the name is spliced in
  -- as a 'String' the way every other binding splices its own.
  | T.null key = prefKey key
  | T.isPrefixOf "kaya." key =
      let name = T.unpack key
       in errorWithoutStackTrace
            ( "kaya: preference key \"" ++ name ++ "\" is reserved "
                ++ "(the kaya. prefix is kaya's own)"
            )
  | otherwise = key

-- | The app's preferences store — one per process.
prefs :: Prefs
prefs =
  Prefs
    { prefGetString = \k d -> maybe d id <$> R.prefGetString (prefKey k),
      prefGetI64 = \k d -> maybe d id <$> R.prefGetI64 (prefKey k),
      prefGetF64 = \k d -> maybe d id <$> R.prefGetF64 (prefKey k),
      prefGetBool = \k d -> maybe d id <$> R.prefGetBool (prefKey k),
      prefSetString = \k v -> R.prefSetString (prefWriteKey k) v,
      prefSetI64 = \k v -> R.prefSetI64 (prefWriteKey k) v,
      prefSetF64 = \k v -> R.prefSetF64 (prefWriteKey k) v,
      prefSetBool = \k v -> R.prefSetBool (prefWriteKey k) v,
      prefRemove = \k -> R.prefRemove (prefWriteKey k)
    }

-- | One clip, offered in as many representations as the app fills in.
data Clip = Clip
  { text :: Maybe Text,
    html :: Maybe Text,
    image :: Maybe BS.ByteString,
    -- | Picked-file handles: copying a file and picking one are the
    -- same currency, so the bytes never move through kaya.
    files :: [PickedFile],
    -- | The one plural field with names, since several app-defined formats
    -- are legitimate.
    custom :: [(Text, BS.ByteString)]
  }

-- | The empty clip, to fill in: @copy emptyClip { text = Just "hi" }@.
emptyClip :: Clip
emptyClip = Clip Nothing Nothing Nothing [] []

-- | ONE REPRESENTATION of a TEMPLATE drag payload (docs/dnd-plan.md §4):
-- a constant, or the ROW'S OWN FIELD, which every stamped copy resolves
-- from its own record — @TplField (field \@"title" \@Item)@ binds the way
-- @label (field \@"title" \@Item)@ does.
data TplRep v = TplConst v | TplField (KField v)

-- | 'Clip' one zone up: what a TEMPLATE node hands over, each
-- representation a constant or the row's own field. A file never binds —
-- a picked handle is not a field.
-- THE ZONE IS IN THE FIELD NAMES, not the type's: 'Clip' carries the
-- same five words, and GHC's DuplicateRecordFields resolves a record
-- UPDATE across two such records by a mechanism it has announced it will
-- drop (-Wambiguous-fields). The @tpl@ prefix is the template zone's own,
-- as 'TplA11yId' is.
data TplClip = TplClip
  { tplText :: Maybe (TplRep Text),
    tplHtml :: Maybe (TplRep Text),
    tplImage :: Maybe (TplRep BS.ByteString),
    tplFiles :: [PickedFile],
    tplCustom :: [(Text, TplRep BS.ByteString)]
  }

-- | The empty template clip, to fill in:
-- @TplDraggable emptyTplClip { tplText = Just (TplField (field \@"title" \@Item)) } [OpCopy]@.
emptyTplClip :: TplClip
emptyTplClip = TplClip Nothing Nothing Nothing [] []

-- | The mode to redeem a picked file's handle in.
data FileMode = FileModeRead | FileModeWrite | FileModeReadWrite

fileModeWire :: FileMode -> Word32
fileModeWire mode = case mode of
  FileModeRead -> W.fileModeRead
  FileModeWrite -> W.fileModeWrite
  FileModeReadWrite -> W.fileModeReadWrite

-- | Redeem the handle for a real 'Handle', plus whether it seeks.
-- BLOCKS, possibly for a long time, so call it from a thread you chose
-- and post the result back.
openPicked :: PickedFile -> FileMode -> IO (Handle, Bool)
openPicked f mode = R.openPicked f.handle (fileModeWire mode)

-- | AN ASSET — a file this app's own BUILD put where the running
-- program can find it (docs\/assets-plan.md).
type Asset = R.Asset

-- | Open an asset by its relative path under the asset root, spelled
-- with @\/@ — @asset "fonts\/sora-wght.ttf"@ (docs\/assets-plan.md;
-- tools/check-assets.py refuses a guest that resolves one itself).
--
-- IO, AND CALLED OUTSIDE THE TRANSACTION: 'Build' is a pure state monad,
-- so a scene opens its assets in the IO around 'buildTx'. A miss raises
-- with the core's sentence verbatim, and EACH CALL READS — no cache.
asset :: Text -> IO Asset
asset = R.openAsset

-- | Why 'asset' would raise for this name — the sentence it would carry,
-- handed over without raising. @""@ means the name resolves. LINE 1 is
-- the same on every platform and is the line a scene freezes; line 2
-- names the resolved place. Authored by @asset_why_not@ in
-- crates\/kaya\/src\/assets.rs.
assetMissSentence :: Text -> IO Text
assetMissSentence = R.assetMissSentence

-- | THE BYTES REDEMPTION: this asset's bytes, copied out of core memory.
assetBytes :: Asset -> IO BS.ByteString
assetBytes = R.assetBytes

-- | Let the core drop these bytes. Idempotent, and a guest that never
-- calls it still leaks nothing.
assetClose :: Asset -> IO ()
assetClose = R.assetClose

-- Live-zone-only vocabulary. (tools/check-sugar-surface.py scans the Tpl
-- instance up to THIS line, so the sentence is load-bearing.)

-- | One per-appearance override of the brand accent, for a brand book that
-- specifies a dark variant.
data BrandAttr
  = -- | The accent to use while the platform is in its LIGHT appearance.
    BLight Word32
  | -- | The accent to use while it is in its DARK one.
    BDark Word32

-- | REQUEST this app's brand accent (docs/styling-plan.md D1/D2): one
-- packed sRGB hex, @0xRRGGBB@, is the whole call, and the
-- per-appearance form adds the attribute list.
--
-- SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write or
-- a late one. The app never writes a foreground or a contrast variant.
brandAccent :: (BrandArgs r) => Word32 -> r
brandAccent = brandish

class BrandArgs r where
  brandish :: Word32 -> r

instance (a ~ ()) => BrandArgs (Build a) where
  brandish seed = emitBrand seed []

instance (a ~ BrandAttr, r ~ Build ()) => BrandArgs ([a] -> r) where
  brandish = emitBrand

emitBrand :: Word32 -> [BrandAttr] -> Build ()
emitBrand seed attrs = emitB (W.txSetBrandAccent seed mask (pack light) (pack dark))
  where
    lastOf p = foldl (\held a -> maybe held Just (p a)) Nothing attrs
    light = lastOf (\a -> case a of BLight c -> Just c; _ -> Nothing)
    dark = lastOf (\a -> case a of BDark c -> Just c; _ -> Nothing)
    -- The wire's presence mask: bit 0 light, bit 1 dark; an absent cell
    -- rides as 0 and the core fills it from the seed.
    mask = maybe 0 (const 1) light + maybe 0 (const 2) dark
    pack = fromMaybe 0

-- | WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
-- @platform@; docs/styling-plan.md Slice 2b).
--
-- AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
-- @currentPlatform@: GHC's @System.Info.os@ reports the COMPILE TARGET
-- and says @darwin@ for both macOS and iOS.
data Platform
  = PlatformMac
  | PlatformIos
  | PlatformLinux
  | PlatformWindows
  | PlatformAndroid
  deriving (Eq, Show)

-- From the generated table, never literals (as 'symbolWire'): the
-- discriminants are spec facts and a hand-typed copy here would drift.
platformWire :: Platform -> Int64
platformWire p = fromIntegral $ case p of
  PlatformMac -> W.platformMac
  PlatformIos -> W.platformIos
  PlatformLinux -> W.platformLinux
  PlatformWindows -> W.platformWindows
  PlatformAndroid -> W.platformAndroid

-- | The optional halves of a brand typeface request, for an app whose
-- default family is not the right name on every platform, or which
-- ships the font itself.
data TypefaceAttr
  = -- | The family to use ON one platform, overriding the default name
    -- for that platform alone: @TFor PlatformLinux "DejaVu Serif"@.
    TFor Platform Text
  | -- | A font FILE, as bytes: the backend hands them to its platform's
    -- app-font API, reads back the family that registration named, and uses
    -- it in preference to any name above.
    TFont BS.ByteString
  | -- | The same font slot with the file NAMED rather than read:
    -- @TFontAsset =<< asset "fonts\/sora-wght.ttf"@ opened in the IO
    -- around 'buildTx'. THE BYTES NEVER ENTER THE HASKELL HEAP: the core
    -- hands the same buffer to the blob table.
    TFontAsset Asset

-- | REQUEST this app's brand typeface (docs/styling-plan.md Slice 2b):
-- @brandTypeface "Georgia"@. THE FAMILY, NEVER THE SCALE.
--
-- SET ONCE, BEFORE THE FIRST MOUNT, like 'brandAccent'. A FAMILY A
-- PLATFORM DOES NOT HAVE LEAVES THAT PLATFORM'S OWN TYPEFACE IN PLACE,
-- deliberately and silently.
brandTypeface :: (TypefaceArgs r) => Text -> r
brandTypeface = typefacish

class TypefaceArgs r where
  typefacish :: Text -> r

instance (a ~ ()) => TypefaceArgs (Build a) where
  typefacish family = emitTypeface family []

instance (a ~ TypefaceAttr, r ~ Build ()) => TypefaceArgs ([a] -> r) where
  typefacish = emitTypeface

emitTypeface :: Text -> [TypefaceAttr] -> Build ()
emitTypeface family attrs =
  emitBIO (W.txSetBrandTypeface mask (W.VStr (T.unpack family)) rows <$> slot)
  where
    -- THE ROWS ARE A LIST AND THE FONT IS A CELL: a repeated 'TFont' is
    -- last-wins, while the 'TFor' rows are NOT folded and NOT
    -- deduplicated — a platform named twice must reach the root and die.
    rows =
      concatMap
        ( \a -> case a of
            TFor p f -> [W.VI64 (platformWire p), W.VStr (T.unpack f)]
            TFont _ -> []
            TFontAsset _ -> []
        )
        attrs
    -- ONE SLOT, TWO WAYS TO FILL IT: they fold together, last written
    -- wins.
    font =
      foldl
        ( \held a -> case a of
            TFont b -> Just (Left b)
            TFontAsset s -> Just (Right s)
            _ -> held
        )
        Nothing
        attrs
    -- The wire's presence mask: bit 0 says a font blob rides the slot.
    mask = maybe 0 (const 1) font
    -- The slot is written either way — an empty Str stands in — so the
    -- record's field count never varies with the payload.
    slot = case font of
      Nothing -> pure (W.VStr "")
      Just (Left b) -> W.VBlob <$> registerBlob b
      Just (Right s) -> W.VBlob <$> R.assetBlob s

-- | DECLARE this app's identity (docs/app-identity-plan.md,
-- docs/tasks-s3-plan.md N4). NO ARGUMENTS: the name it goes by, the
-- picture that stands for it and the reverse-DNS id it registers under
-- are the asset root's own identity.toml, which the BUILD already reads,
-- and the core reads the same file. SET ONCE, BEFORE THE FIRST MOUNT.
--
-- STILL AN EXPLICIT CALL, because declaring an identity is a POLICY: a
-- declared app is a Dock app on macOS (ruling 1), so an app that wants
-- the platform's own identity declares none at all.
appIdentity :: Build ()
appIdentity =
  -- THE SLOTS RIDE EMPTY and the root fills them from the asset root's own
  -- identity.toml: mask 0, no name, no blob. The record's shape is fixed, so
  -- the icon slot is written either way, as an empty Str.
  emitB (W.txSetAppIdentity 0 (W.VStr "") (W.VStr ""))

-- | Window construction attributes — the config-list spelling. The
-- handler attrs ride the declaration: 'WOnCloseRequested' fires per
-- chrome close while veto_close is armed (answer with 'destroyWindow'
-- to agree); 'WOnClosed' fires when the non-veto auxiliary is
-- chrome-closed and retires with it.
data WindowAttr
  = WTitle Text
  | WSize Double Double
  | WVetoClose Bool
  | -- | The CEILING on how many of this window's stack entries present
    -- side by side: 1 is the serial stack, 2 and 3 are columns on a
    -- window wide enough, the shallowest shed first as it narrows
    -- (docs/multicolumn-plan.md). The live count is the platform's own
    -- judgment where it has one; the root refuses 0 and anything above 3.
    WPanes Word32
  | WSectionsPresentation SectionsPresentation
  | -- | The app's OWN light\/dark choice, applied process-wide from the
    -- default window (docs\/tasks-s2b-plan.md R1-R3): 'AppearanceSystem'
    -- defers to the harness knob and then the OS, the other two win over
    -- both.
    WAppearance Appearance
  | -- | Whether this surface holds unsaved work (docs/dirty-plan.md
    -- D1). 'WTitle' IS NEVER TOUCHED BY IT — kaya's titles are
    -- byte-compared across platforms.
    WDirty Bool
  | -- | The OPT-OUT from window memory (docs/tasks-s4-plan.md P4): a
    -- desktop window reopens at the frame the previous process left
    -- unless this is False. Inert on the phones.
    WRememberFrame Bool
  | -- | The space kaya's own interpreters put around this window's
    -- mounted root, in layout units — LAYOUT, not appearance
    -- (docs/styling-plan.md D3).
    WInset Double
  | WOnCloseRequested (IO ())
  | WOnClosed (IO ())
  | -- | Hear an undo kaya routed in this window: the step's label —
    -- EMPTY for a typing episode — and what the core put back. THE
    -- DELTA IS THE ONLY NOTIFICATION (the echo doctrine).
    WOnUndone (Text -> UndoDelta -> IO ())
  | -- | The 'WOnUndone' twin. A frontier typing episode redoes on the
    -- platform's own stack and reports itself as an ordinary edit, so
    -- that one does not arrive here.
    WOnRedone (Text -> UndoDelta -> IO ())
  | -- | The menubar rides the window construct: 'WMenus' realizes its
    -- inline Build actions in order and appends each top-level grouping
    -- node to this window's catalog — append-only, at any time.
    WMenus [Build (MItem 'BarM)]

-- | Set a window's attributes in one construct — the attribute set is
-- EXACTLY 'createWindow''s: @window 0 [WTitle "sections",
-- WSectionsPresentation 1]@.
-- | The one window every process owns and never creates or destroys
-- (DESIGN.md, Binding conventions) — @window primary [...]@ rather than
-- the bare literal.
primary :: Word64
primary = 0

window :: Word64 -> [WindowAttr] -> Build ()
window n = mapM_ apply
  where
    apply (WTitle t) = emitB (W.txSetWindowTitle n (T.unpack t))
    apply (WSize w h) = do
      emitB (W.txSetWindowWidth n w)
      emitB (W.txSetWindowHeight n h)
    apply (WVetoClose v) = emitB (W.txSetWindowVetoClose n v)
    apply (WPanes ceiling') = emitB (W.txSetWindowPanes n (fromIntegral ceiling'))
    apply (WSectionsPresentation p) = emitB (W.txSetWindowSectionsPresentation n (sectionsPresentationWire p))
    apply (WAppearance a) = emitB (W.txSetWindowAppearance n (appearanceWire a))
    apply (WDirty v) = emitB (W.txSetWindowDirty n v)
    apply (WRememberFrame v) = emitB (W.txSetWindowRememberFrame n v)
    apply (WInset units) = emitB (W.txSetWindowInset n units)
    apply (WOnCloseRequested handler) = pendB (PCloseRequested n handler)
    apply (WOnClosed handler) = pendB (PWindowClosed n handler)
    apply (WOnUndone handler) = pendB (PUndone n handler)
    apply (WOnRedone handler) = pendB (PRedone n handler)
    apply (WMenus menus) =
      mapM_ (\m -> m >>= \(MItem i) -> emitB (W.txMenubarAppend n i)) menus

-- | Create an auxiliary window (capability-gated: phone hosts reject
-- at the root); materializes hidden, 'mountIn' presents:
-- @createWindow 1 [WTitle "inspector", WSize 480 320, WVetoClose True]@.
createWindow :: Word64 -> [WindowAttr] -> Build ()
createWindow n attrs = do
  emitB (W.txCreateWindow n)
  window n attrs

-- | Close and forget an auxiliary window — also the veto grammar's
-- confirmation and the reconciliation after a chrome close.
destroyWindow :: Word64 -> Build ()
destroyWindow n = emitB (W.txDestroyWindow n)

-- | Mount a root into a specific window; mounting presents.
mountIn :: Word64 -> Widget -> Build ()
mountIn window (Widget n) = emitB (W.txMount window n)

-- | Navigation-entry construction attributes — the config-list
-- spelling. 'EOnPopped' fires when the user's back affordance pops THIS
-- entry natively (a programmatic 'popEntry' does not fire it) and
-- retires with the one pop; 'EOnBack' fires per back request while
-- intercept_back is armed — nothing has popped, answer with 'popEntry'
-- to agree.
data EntryAttr
  = ETitle Text
  | EInterceptBack Bool
  | EOnPopped (IO ())
  | EOnBack (IO ())

data SectionAttr
  = STitle Text
  | -- | The switcher item's SEMANTIC ICON ('Symbol'): a concept each
    -- backend draws in its own platform's symbol set.
    SSymbol Symbol
  | -- | The COUNT on the switcher item (docs\/tasks-s2-plan.md T2): the
    -- platforms draw it where they draw a badge, GTK as a pill on the
    -- row. Zero clears.
    SBadge Double
  | -- | The count from a signal, so a changing total moves the badge
    -- without a rebuild.
    SBadgeBound (Signal Double)
  | SOnSelected (IO ())

-- | Push a navigation entry onto the primary surface's stack (entry ids
-- are guest-allocated in the shared surface namespace); materializes
-- covered, 'mountIn' presents it.
pushEntry :: Word64 -> [EntryAttr] -> Build ()
pushEntry n attrs = do
  emitB (W.txPushEntry 0 n)
  mapM_ apply attrs
  where
    apply (ETitle t) = emitB (W.txSetEntryTitle n (T.unpack t))
    apply (EInterceptBack v) = emitB (W.txSetEntryInterceptBack n v)
    apply (EOnPopped handler) = pendB (PEntryPopped n handler)
    apply (EOnBack handler) = pendB (PBackRequested n handler)

-- | Pop the primary stack's top navigation entry and forget its tree — also
-- the back-veto grammar's confirmation after 'onBackRequested'.
popEntry :: Build ()
popEntry = emitB (W.txPopEntry 0)

-- | The height the phones open a sheet at (docs\/sheet-plan.md §1.4); the
-- desktops have nothing to say and ignore it.
data Detent = DetentMedium | DetentLarge
  deriving (Eq, Show)

detentWire :: Detent -> Int64
detentWire d = fromIntegral $ case d of
  DetentMedium -> W.detentMedium
  DetentLarge -> W.detentLarge

-- | Sheet construction attributes (docs\/sheet-plan.md) — the config-list
-- spelling. 'ShOnDismissed' fires when the user's cancel path closes THIS
-- sheet natively (a programmatic 'dismissSheet' does not fire it) and
-- retires with the one dismissal; 'ShOnDismissRequested' fires per cancel
-- while intercept_dismiss is armed — nothing has gone, answer with
-- 'dismissSheet' to agree.
data SheetAttr
  = ShTitle Text
  | ShInterceptDismiss Bool
  | ShDetent Detent
  | ShOnDismissed (IO ())
  | ShOnDismissRequested (IO ())

-- | Request a sheet over the primary window (sheet ids are guest-allocated
-- in the shared surface namespace); 'mountIn' presents it.
presentSheet :: Word64 -> [SheetAttr] -> Build ()
presentSheet = presentSheetOver 0

-- | Request a sheet over another window or over a LIVE SHEET (the chain:
-- one child per parent).
presentSheetOver :: Word64 -> Word64 -> [SheetAttr] -> Build ()
presentSheetOver parent n attrs = do
  emitB (W.txPresentSheet parent n)
  mapM_ apply attrs
  where
    apply (ShTitle t) = emitB (W.txSetSheetTitle n (T.unpack t))
    apply (ShInterceptDismiss v) = emitB (W.txSetSheetInterceptDismiss n v)
    apply (ShDetent d) = emitB (W.txSetSheetDetent n (detentWire d))
    apply (ShOnDismissed handler) = pendB (PSheetDismissed n handler)
    apply (ShOnDismissRequested handler) = pendB (PDismissRequested n handler)

-- | Dismiss a live sheet and forget its tree, child sheets with it — also
-- the dismiss-veto grammar's confirmation after 'ShOnDismissRequested'.
dismissSheet :: Word64 -> Build ()
dismissSheet n = emitB (W.txDismissSheet n)

-- | Append a section to the primary window's section set; the set is
-- append-only — sections have no destruction grammar, and every
-- section's root is retained while covered (switching is SELECTION, not
-- lifecycle). 'SOnSelected' fires each time the USER switches to it —
-- NOT one-shot; a programmatic 'selectSection' does not fire it (the
-- echo doctrine).
addSection :: Word64 -> [SectionAttr] -> Build ()
addSection = addSectionIn 0

-- | 'addSection' with the HOST WINDOW said out loud — 0 is the primary, an
-- aux window's id otherwise.
addSectionIn :: Word64 -> Word64 -> [SectionAttr] -> Build ()
addSectionIn w n attrs = do
  emitB (W.txAddSection w n)
  mapM_ apply attrs
  where
    apply (STitle t) = emitB (W.txSetSectionTitle n (T.unpack t))
    apply (SSymbol s) = emitB (W.txSetSectionSymbol n (symbolWire s))
    apply (SBadge c) = emitB (W.txSetSectionBadge n c)
    apply (SBadgeBound (Signal s)) = emitB (W.txBindSectionBadge n s)
    apply (SOnSelected handler) = pendB (PSectionSelected n handler)

-- | Select a section programmatically: configuration, never echoes
-- 'SOnSelected' (the echo doctrine).
selectSection :: Word64 -> Build ()
selectSection n = emitB (W.txSelectSection 0 n)

-- | HOW A WINDOW PRESENTS ITS SECTION SET (spec enum
-- @sections_presentation@): the platform's own judgment, a bar, or a
-- sidebar.
data SectionsPresentation = SectionsAuto | SectionsBar | SectionsSidebar
  deriving (Eq, Show)

sectionsPresentationWire :: SectionsPresentation -> Int64
sectionsPresentationWire p = fromIntegral $ case p of
  SectionsAuto -> W.sectionsPresentationAuto
  SectionsBar -> W.sectionsPresentationBar
  SectionsSidebar -> W.sectionsPresentationSidebar

-- | THE APP'S OWN LIGHT\/DARK CHOICE (spec enum @appearance@).
data Appearance = AppearanceSystem | AppearanceLight | AppearanceDark
  deriving (Eq, Show)

appearanceWire :: Appearance -> Int64
appearanceWire a = fromIntegral $ case a of
  AppearanceSystem -> W.appearanceSystem
  AppearanceLight -> W.appearanceLight
  AppearanceDark -> W.appearanceDark

-- | THE SEMANTIC ICON VOCABULARY (spec enum @symbol@; DESIGN.md "Icons
-- want names, not bytes"; docs/styling-plan.md D6), shared by 'SSymbol'
-- on a section and 'ISymbol' on a menu item.
data Symbol
  = SymbolAdd
  | SymbolRemove
  | -- | Destroying something, the wastebasket idiom — distinct from
    -- 'SymbolRemove', which takes an item out of a list.
    SymbolDelete
  | SymbolEdit
  | -- | Confirmation, the checkmark idiom.
    SymbolDone
  | -- | Dismissal, the ✕ idiom — not 'SymbolDelete'.
    SymbolClose
  | SymbolSearch
  | SymbolSettings
  | SymbolRefresh
  | SymbolInfo
  | SymbolWarning
  | -- | The direction-relative pair: every platform mirrors these under
    -- a right-to-left layout, so they mean BACKWARD and FORWARD in
    -- reading order, never "left" and "right".
    SymbolBack
  | SymbolForward
  | -- | The overflow affordance (the ellipsis idiom).
    SymbolMore
  | SymbolCopy
  | SymbolPaste
  | -- | Favourite.
    SymbolStar
  | SymbolLock
  | -- | A person or account.
    SymbolPerson
  | SymbolHome
  deriving (Eq, Show)

-- From the generated table, never literals: the discriminants are spec
-- facts, append-only, and a hand-typed copy here would drift.
symbolWire :: Symbol -> Int64
symbolWire s = fromIntegral $ case s of
  SymbolAdd -> W.symbolAdd
  SymbolRemove -> W.symbolRemove
  SymbolDelete -> W.symbolDelete
  SymbolEdit -> W.symbolEdit
  SymbolDone -> W.symbolDone
  SymbolClose -> W.symbolClose
  SymbolSearch -> W.symbolSearch
  SymbolSettings -> W.symbolSettings
  SymbolRefresh -> W.symbolRefresh
  SymbolInfo -> W.symbolInfo
  SymbolWarning -> W.symbolWarning
  SymbolBack -> W.symbolBack
  SymbolForward -> W.symbolForward
  SymbolMore -> W.symbolMore
  SymbolCopy -> W.symbolCopy
  SymbolPaste -> W.symbolPaste
  SymbolStar -> W.symbolStar
  SymbolLock -> W.symbolLock
  SymbolPerson -> W.symbolPerson
  SymbolHome -> W.symbolHome

-- --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

-- | The anchor scope a catalog belongs to, as a phantom index: 'BarM
-- is a window catalog (a shortcut home), 'CtxM a context anchor. A
-- shortcut on a context item — or a keyed handler on a bar item — is a
-- TYPE error; the runtime guard at the root remains the floor beneath.
data MScope = BarM | CtxM

-- | A live menu item: its OWN id space behind its own type (indexed by anchor
-- scope), so cross-use with 'Widget'/'Node' handles is a type error.
newtype MItem (s :: MScope) = MItem Word64

-- | A radio option: its own type, so an option outside a 'radioGroup'
-- children list — or a non-option inside one — is a type error (the
-- closed parent/child grammar, compile-checked).
newtype MOption (s :: MScope) = MOption Word64

-- | A context catalog built UNANCHORED ('contextCatalog') for a template
-- node: menu items are live and shared across stamped copies, so the
-- catalog is built in the live zone and 'nodeContextMenu' attaches it.
newtype Catalog = Catalog [Word64]

-- | A named vocabulary for the accept list's closed half. A MISTYPED
-- BARE STRING IS SILENT: it becomes a custom format id no clipboard will
-- ever offer, so Paste stays dead and the paste hook never fires.
acceptText :: Text
acceptText = "text"
acceptHtml :: Text
acceptHtml = "html"
acceptImage :: Text
acceptImage = "image"
acceptFiles :: Text
acceptFiles = "files"

roleSettings :: Text
roleSettings = "settings"

-- | The three clipboard commands. They lower to the platform's own, act
-- on the FOCUSED widget, and work out their own enablement from what
-- the clipboard offers and what that widget accepts.
roleCut :: Text
roleCut = "cut"

roleCopy :: Text
roleCopy = "copy"

rolePaste :: Text
rolePaste = "paste"

-- | The two history commands (docs/undo-plan.md D6). They ask the
-- FOCUSED widget first — a text field with its own edit history answers
-- before the app's ledger does — and enablement is that same question,
-- asked live at activation.
roleUndo :: Text
roleUndo = "undo"

roleRedo :: Text
roleRedo = "redo"

-- | Menu item construction attributes — the config-list spelling over
-- a closed GADT indexed by anchor scope. Label and enablement are
-- signal-bindable; 'IChecked'/'IValue' bind both ways (programmatic
-- writes are QUIET — the echo doctrine); icon, primary and shortcut are
-- const-only. The @Node@ flavors receive the stamped copy's key path.
data IAttr (s :: MScope) where
  -- | Bind the label to a Str signal (constant labels are the
  -- creator's positional argument).
  ILabel :: Signal Text -> IAttr s
  IEnabled :: Bool -> IAttr s
  IEnabledBy :: Signal Bool -> IAttr s
  IChecked :: Bool -> IAttr s
  ICheckedBy :: Signal Bool -> IAttr s
  IValue :: Int -> IAttr s
  IValueBy :: Signal Double -> IAttr s
  IIcon :: BS.ByteString -> IAttr s
  -- | The item's SEMANTIC ICON ('Symbol'). BESIDE 'IIcon', not instead
  -- of it: app-specific art still rides the blob. Const-only, so there
  -- is no bind flavor.
  ISymbol :: Symbol -> IAttr s
  IPrimary :: Bool -> IAttr s
  -- | Any window-anchored LEAF command: a chord needs a window catalog
  -- as its native dispatch home, and the type carries that rule.
  IShortcut :: Text -> IAttr 'BarM
  -- | Window-anchored actions only: a role names a standard command in the
  -- window catalog.
  IRole :: Text -> IAttr 'BarM
  IOnActivate :: IO () -> IAttr s
  IOnActivateNode :: ([Key] -> IO ()) -> IAttr 'CtxM
  IOnToggle :: (Bool -> IO ()) -> IAttr s
  IOnToggleNode :: ([Key] -> Bool -> IO ()) -> IAttr 'CtxM
  IOnSelect :: (Int -> IO ()) -> IAttr s
  IOnSelectNode :: ([Key] -> Int -> IO ()) -> IAttr 'CtxM

applyIAttr :: Word64 -> IAttr s -> Build ()
applyIAttr n attr = case attr of
  ILabel (Signal s) -> emitB (W.txBindMenuLabel n s)
  IEnabled v -> emitB (W.txSetMenuEnabled n v)
  IEnabledBy (Signal s) -> emitB (W.txBindMenuEnabled n s)
  IChecked v -> emitB (W.txSetMenuChecked n v)
  ICheckedBy (Signal s) -> emitB (W.txBindMenuChecked n s)
  IValue v -> emitB (W.txSetMenuValue n (fromIntegral v))
  IValueBy (Signal s) -> emitB (W.txBindMenuValue n s)
  IIcon bytes -> emitBIO (W.txSetMenuIcon n <$> registerBlob bytes)
  ISymbol s -> emitB (W.txSetMenuSymbol n (symbolWire s))
  IPrimary v -> emitB (W.txSetMenuPrimary n v)
  IShortcut spelling -> emitB (W.txSetMenuShortcut n (T.unpack spelling))
  IRole name -> emitB (W.txSetMenuRole n (T.unpack name))
  IOnActivate handler -> pendB (PMenuActivated n handler)
  IOnActivateNode handler -> pendB (PMenuActivatedNode n handler)
  IOnToggle handler -> pendB (PMenuToggled n handler)
  IOnToggleNode handler -> pendB (PMenuToggledNode n handler)
  IOnSelect handler -> pendB (PMenuSelected n handler)
  IOnSelectNode handler -> pendB (PMenuSelectedNode n handler)

newMenuItem :: Word32 -> Maybe Text -> [IAttr s] -> Build Word64
newMenuItem kind label attrs = do
  n <- allocM
  emitB (W.txMenuItemCreate n kind)
  mapM_ (emitB . W.txSetMenuLabel n . T.unpack) label
  mapM_ (applyIAttr n) attrs
  return n

-- | An action — a leaf command firing exactly one menu_activated
-- occurrence (menu click OR its shortcut: ONE occurrence, one dispatch
-- path): @item "Save" [IShortcut "primary+s", IOnActivate h]@.
item :: Text -> [IAttr s] -> Build (MItem s)
item label attrs = MItem <$> newMenuItem W.menuKindAction (Just label) attrs

-- | A toggle — a stateful leaf reusing the Checkbox contract: user
-- flips emit menu_toggled ('IOnToggle' receives the new state);
-- programmatic 'IChecked' writes are QUIET.
toggle :: Text -> [IAttr s] -> Build (MItem s)
toggle label attrs = MItem <$> newMenuItem W.menuKindToggle (Just label) attrs

-- | One labeled radio option, appended in declaration order — the
-- order IS the index vocabulary the group's value selects over.
option :: Text -> [IAttr s] -> Build (MOption s)
option label attrs = MOption <$> newMenuItem W.menuKindRadioOption (Just label) attrs

-- | Native grouping chrome: no label, no props, no handler.
separator :: Build (MItem s)
separator = MItem <$> newMenuItem W.menuKindSeparator Nothing []

-- | A menu grouping node — a bar root through 'WMenus', or nested
-- inline in a parent's child list (one nested grouping level is the cap,
-- root-checked).
menu :: Text -> [IAttr s] -> [Build (MItem s)] -> Build (MItem s)
menu label attrs children = do
  n <- newMenuItem W.menuKindMenu (Just label) []
  mapM_ (\child -> child >>= \(MItem c) -> emitB (W.txMenuItemAppend n c)) children
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A radio group — the Choice contract with the platform's checkmark
-- idiom. The children are 'option's ONLY (their type holds the closed
-- grammar); 'IValue'\/'IValueBy' is the selected 0-based index, applied
-- AFTER the options so the index has options to address.
radioGroup :: Text -> [IAttr s] -> [Build (MOption s)] -> Build (MItem s)
radioGroup label attrs options = do
  n <- newMenuItem W.menuKindRadioGroup (Just label) []
  mapM_ (\child -> child >>= \(MOption c) -> emitB (W.txMenuItemAppend n c)) options
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A context menu on a LIVE widget: the same item vocabulary scoped to a
-- NOUN, with the platform's own gesture (right-click, long-press).
contextMenu :: Widget -> [Build (MItem 'CtxM)] -> Build ()
contextMenu (Widget w) roots =
  mapM_ (\root -> root >>= \(MItem n) -> emitB (W.txContextAttach w n)) roots

-- | Build a context catalog UNANCHORED — free root items for a
-- template-node anchor; 'nodeContextMenu' attaches it inside the
-- template, and each activation carries the copy's key path.
contextCatalog :: [Build (MItem 'CtxM)] -> Build Catalog
contextCatalog roots =
  Catalog <$> mapM (\root -> (\(MItem n) -> n) <$> root) roots

-- | Attach a live-built context catalog to a template node: each
-- activation carries that copy's key path — the keys ARE the noun.
nodeContextMenu :: Node -> Catalog -> Tpl ()
nodeContextMenu (Node n) (Catalog roots) =
  mapM_ (emitT . W.txContextAttachNode n) roots

setMenuLabel :: MItem s -> Text -> Build ()
setMenuLabel (MItem n) label = emitB (W.txSetMenuLabel n (T.unpack label))

bindMenuLabel :: MItem s -> Signal Text -> Build ()
bindMenuLabel (MItem n) (Signal s) = emitB (W.txBindMenuLabel n s)

setMenuEnabled :: MItem s -> Bool -> Build ()
setMenuEnabled (MItem n) v = emitB (W.txSetMenuEnabled n v)

bindMenuEnabled :: MItem s -> Signal Bool -> Build ()
bindMenuEnabled (MItem n) (Signal s) = emitB (W.txBindMenuEnabled n s)

setMenuChecked :: MItem s -> Bool -> Build ()
setMenuChecked (MItem n) v = emitB (W.txSetMenuChecked n v)

bindMenuChecked :: MItem s -> Signal Bool -> Build ()
bindMenuChecked (MItem n) (Signal s) = emitB (W.txBindMenuChecked n s)

setMenuValue :: MItem s -> Int -> Build ()
setMenuValue (MItem n) v = emitB (W.txSetMenuValue n (fromIntegral v))

bindMenuValue :: MItem s -> Signal Double -> Build ()
bindMenuValue (MItem n) (Signal s) = emitB (W.txBindMenuValue n s)

setMenuIcon :: MItem s -> BS.ByteString -> Build ()
setMenuIcon (MItem n) bytes = emitBIO (W.txSetMenuIcon n <$> registerBlob bytes)

-- | The item's SEMANTIC ICON, dynamic path — the declarative spelling is the
-- 'ISymbol' attr.
setMenuSymbol :: MItem s -> Symbol -> Build ()
setMenuSymbol (MItem n) s = emitB (W.txSetMenuSymbol n (symbolWire s))

-- | The phone-bar promotion hint (actions only — root-checked).
-- Flipping it recomputes the promoted set deterministically; INERT on
-- desktops — not a toolbar grammar.
setMenuPrimary :: MItem s -> Bool -> Build ()
setMenuPrimary (MItem n) v = emitB (W.txSetMenuPrimary n v)

-- | The action's shortcut (window-anchored actions only), canonicalized
-- by 'W.canonicalizeShortcut'. The shortcut fires the SAME
-- menu_activated occurrence as a click.
setMenuShortcut :: MItem s -> Text -> Build ()
setMenuShortcut (MItem n) spelling = emitB (W.txSetMenuShortcut n (T.unpack spelling))

-- | Declare a retained action a standard command (actions only — root-
-- checked).
setMenuRole :: MItem 'BarM -> Text -> Build ()
setMenuRole (MItem n) name = emitB (W.txSetMenuRole n (T.unpack name))

-- | Reopen a RETAINED grouping node and append more children — the
-- append-at-any-time discipline.
menuAppend :: MItem s -> [Build (MItem s)] -> Build ()
menuAppend (MItem n) children =
  mapM_ (\child -> child >>= \(MItem c) -> emitB (W.txMenuItemAppend n c)) children

-- | The option-flavored reopening, for a retained radio group.
menuOptions :: MItem s -> [Build (MOption s)] -> Build ()
menuOptions (MItem n) options =
  mapM_ (\child -> child >>= \(MOption c) -> emitB (W.txMenuItemAppend n c)) options

-- | Alert construction attributes — the config-list spelling.
data AlertAttr
  = ATitle Text
  | AMessage Text
  | AAction Text
  | ACancel Text

-- | Request a modal alert (the request/result grammar), the handler
-- riding the request. The handler fires exactly once — choice is an
-- action index (0 or 1) or 'W.alertChoiceCancel' — and its registration
-- retires with the result. AT MOST TWO AActions (the platform floor)
-- and EXACTLY ONE ACancel, required.
showAlert :: [AlertAttr] -> (AlertChoice -> IO ()) -> Build ()
showAlert attrs handler = do
  let titles = [t | ATitle t <- attrs]
      messages = [m | AMessage m <- attrs]
      actions = [a | AAction a <- attrs]
      cancels = [c | ACancel c <- attrs]
  case () of
    _
      | length actions > 2 ->
          error "kaya: an alert carries at most 2 actions (the platform floor)"
      | null cancels || any T.null cancels ->
          error "kaya: the cancel slot always exists and needs a name — add ACancel"
      | otherwise -> do
          n <- state $ \s ->
            let c = s.bCounters
                next = c.cAlert + 1
             in (next, s {bCounters = c {cAlert = next}})
          pendB (PAlert n handler)
          emitB
            ( W.txShowAlert
                0
                n
                (fromIntegral (length actions))
                (W.VStr (T.unpack (mconcat (take 1 titles))))
                (W.VStr (T.unpack (mconcat (take 1 messages))))
                (W.VStr (T.unpack (mconcat (take 1 actions))))
                (W.VStr (T.unpack (mconcat (take 1 (drop 1 actions)))))
                (W.VStr (T.unpack (mconcat (take 1 cancels))))
            )

-- | Notification construction attributes — the config-list spelling,
-- 'AlertAttr' one request over.
data NotificationAttr
  = NTitle Text
  | NBody Text
  | -- | When the platform fires it: a UNIX time in seconds, handed to
    -- the OS scheduler where one exists. Absent (0) posts now.
    NAt Word64

-- | Post a local notification with a GUEST-CHOSEN id
-- (docs/tasks-s3-plan.md N1, N2): the alert's grammar without a window,
-- the handler riding the request. It fires exactly once — the outcome is
-- 'W.notificationOutcomeActivated' or 'W.notificationOutcomeRefused' —
-- and its registration retires with the result. A title is REQUIRED.
-- Many notifications may be live at once.
showNotification :: Word64 -> [NotificationAttr] -> (NotificationOutcome -> IO ()) -> Build ()
showNotification notification attrs handler = do
  let titles = [t | NTitle t <- attrs]
      bodies = [b | NBody b <- attrs]
      ats = [a | NAt a <- attrs]
  case () of
    _
      | null titles || any T.null titles ->
          error "kaya: a notification needs a title — add NTitle"
      | otherwise -> do
          pendB (PNotification notification handler)
          emitB
            ( W.txShowNotification
                notification
                (case ats of a : _ -> a; [] -> 0)
                (W.VStr (T.unpack (mconcat (take 1 titles))))
                (W.VStr (T.unpack (mconcat (take 1 bodies))))
            )

-- | Withdraw a pending or delivered notification (a reminder that was
-- cleared). No answer follows; an unknown id is ignored.
cancelNotification :: Word64 -> Build ()
cancelNotification notification = emitB (W.txCancelNotification notification)

-- | Register the PROCESS-LEVEL notification handler
-- (docs/tasks-s9-plan.md R1): the handler receives every result whose id
-- has no one-shot handler bound at 'showNotification' — which is the
-- whole of a process the platform RELAUNCHED for a tap, since it never
-- called it. It does not retire, and a one-shot handler for the same id
-- still wins. An App action, not a 'Build' one: it needs no transaction.
onNotificationActivation :: App -> (Word64 -> NotificationOutcome -> IO ()) -> IO ()
onNotificationActivation app handler =
  writeIORef (app.appNotificationActivation) (Just handler)

-- | Declare a link ROUTE and the handler that answers it
-- (docs/app-links-plan.md §4): @linkRoute app \"task\/{key}\" f@ matches
-- @\<scheme\>:\/\/task\/t1@ and calls f with
-- @Map.fromList [(\"key\", \"t1\")]@. Segments split on @\/@, @{name}@
-- captures one segment, a literal segment matches itself; the query's
-- pairs join the params and a capture wins a name clash.
--
-- PROCESS-LEVEL, 'onNotificationActivation''s shape and an App action
-- for the same reason: it does not retire and it needs no transaction —
-- declared before the first one the record waits and rides the head of
-- it, declared inside a handler it rides that handler's. A URL that
-- arrives before the app thread exists is delivered first, and one no
-- route matched is announced by the core and reaches nothing here.
--
-- NOTHING HERE READS THE PATTERN. The core is the one parser and the one
-- author of every refusal — an empty pattern, an empty segment, a
-- malformed one, a duplicate — and it faults at apply with the whole
-- sentence, where every other declaration refusal in kaya lands
-- (tools\/check-sugar-surface.py refuses a reason spelled here).
linkRoute :: App -> Text -> (Map.Map Text Text -> IO ()) -> IO ()
linkRoute app pattern handler = do
  taken <- readIORef (app.appNextLinkRoute)
  let route = taken + 1
  writeIORef (app.appNextLinkRoute) route
  modifyIORef' (app.appLinkHandlers) (Map.insert route handler)
  modifyIORef' (app.appPendingRoutes) (++ [W.txDeclareLinkRoute route (W.VStr (T.unpack pattern))])

-- | The link_opened decision, in a function of its own because the ring
-- loop's branch has no seam a test can reach (the ring is C memory) —
-- 'notificationResult' for the same reason, and guests\/haskell's
-- @kaya-notify-order-check@ drives the cases through here. TWO DROPS
-- WITH DISJOINT CAUSES (docs\/app-links-plan.md §4): route 0 is a URL NO
-- ROUTE TOOK, which the core announced naming every declared pattern, so
-- it is silent here; a route that matched and reached no handler is this
-- binding's to announce, naming its own registrar.
linkOpened :: App -> Word64 -> Text -> Map.Map Text Text -> IO ()
linkOpened app route url params = do
  handlers <- readIORef (app.appLinkHandlers)
  case Map.lookup route handlers of
    Just handler -> dispatch (handler params)
    Nothing
      | route == 0 -> return ()
      | otherwise ->
          -- The drop's own sentence is byte-compared across the nine
          -- bindings (tools/check-sugar-surface.py), so the URL is
          -- spliced in as a 'String', as every other binding splices its
          -- own.
          let opened = T.unpack url
           in hPutStrLn
            stderr
            ( "kaya: link "
                ++ opened
                ++ " matched route "
                ++ show route
                ++ " and reached no handler — none is registered for it"
                ++ " (KayaApp.linkRoute)"
            )

-- | Check one accept-list entry and return it. Ids reach every
-- platform's own registry verbatim, so they carry no spaces.
acceptToken :: Text -> Text
acceptToken kind
  | T.null kind || T.any (== ' ') kind =
      error
        ( "kaya: "
            ++ show kind
            ++ " is not an accept-list entry — the closed kinds are "
            ++ "acceptText, acceptHtml, acceptImage and acceptFiles, and a "
            ++ "custom format id reaches the platform's own registry "
            ++ "verbatim, so it carries no spaces"
        )
  | otherwise = kind

-- | Join an accept list: the closed kinds by name plus any custom ids,
-- space separated.
acceptList :: [Text] -> Text
acceptList = T.unwords . map acceptToken

-- | Put ONE clip on the system clipboard:
-- @copy emptyClip { text = Just "kaya clip" }@.
copy :: Clip -> Build ()
copy clip = emitBIO $ do
  customValues <-
    concat
      <$> mapM
        ( \(ident, bytes) -> do
            h <- registerBlob bytes
            return [W.VStr (T.unpack (acceptToken ident)), W.VBlob h]
        )
        (clip.custom)
  imageValue <- case clip.image of
    Nothing -> return []
    Just bytes -> (: []) . W.VBlob <$> registerBlob bytes
  let present =
        maybe 0 (const W.clipText) (clip.text)
          + maybe 0 (const W.clipHtml) (clip.html)
          + maybe 0 (const W.clipImage) (clip.image)
      files = map (W.VI64 . fromIntegral . (.handle)) (clip.files)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] (\h -> [W.VStr (T.unpack h)]) (clip.html)
          ++ maybe [] (\t -> [W.VStr (T.unpack t)]) (clip.text)
  return
    ( W.txCopy
        present
        (fromIntegral (length (clip.files)))
        (fromIntegral (length (clip.custom)))
        values
    )

-- | Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE. The
-- platforms have deliberately made it expensive (DESIGN.md, and
-- docs/clipboard-plan.md): reach for it to detect a URL or import, never to
-- implement Paste — that is the Paste command, and it is free.
readClipboard :: [Text] -> (Maybe Representation -> IO ()) -> Build ()
readClipboard accepting handler = do
  n <- state $ \st ->
    let c = st.bCounters
        next = c.cClipboardRead + 1
     in (next, st {bCounters = c {cClipboardRead = next}})
  pendB (PClipboardRead n handler)
  emitB (W.txReadClipboard n (W.VStr (T.unpack (acceptList accepting))))

-- | Declare what a widget takes from a paste — the dynamic path; the
-- declarative spelling is the 'Accepts' attribute at construction.
setAccepts :: Widget -> [Text] -> Build ()
setAccepts (Widget w) kinds = emitB (W.txSetAccepts w (T.unpack (acceptList kinds)))

-- | The drag_op mask a guest's operations name; the empty list
-- withdraws the declaration.
operationMask :: [Op] -> Word32
operationMask = foldr (\o m -> m + opMask o) 0
  where
    opMask OpCopy = W.dragOpCopy
    opMask OpMove = W.dragOpMove

-- | The drag_op word, or 'Nothing' for a cancelled or refused drag.
operationOf :: Word32 -> Maybe Op
operationOf m
  | m == W.dragOpCopy = Just OpCopy
  | m == W.dragOpMove = Just OpMove
  | otherwise = Nothing

-- | DECLARE what a widget hands over when dragged: a clip in 'copy''s
-- own shapes plus the operations it allows (docs\/dnd-plan.md D1) — the
-- dynamic path; the declarative spelling is the 'Draggable' attribute
-- at construction. An EMPTY clip withdraws the declaration, which is
-- how a same-app move removes its source (D2).
--
-- LIVE WIDGETS ONLY, and the argument type is the refusal: the template
-- zone lands with its own slice (docs\/dnd-plan.md §4).
setDragSource :: Widget -> Clip -> [Op] -> Build ()
setDragSource (Widget w) clip ops = emitBIO (dragSourceRecord w [] clip ops)

-- | The TEMPLATE builder (docs/dnd-plan.md §4): the reps in canonical
-- order, a bound slot carrying the i64 @level << 32 | field@ under the
-- @bound@ mask. Level 0 is the row this template is stamped for, as it
-- is in every bind*Field binder.
tplDragSourceRecord :: Word64 -> TplClip -> [Op] -> IO Builder
tplDragSourceRecord w clip ops = do
  customValues <-
    concat
      <$> mapM
        ( \(ident, rep) -> case rep of
            TplField (KField i) ->
              return [W.VStr (T.unpack (acceptToken ident)), W.VI64 (fromIntegral i)]
            TplConst bytes -> do
              h <- registerBlob bytes
              return [W.VStr (T.unpack (acceptToken ident)), W.VBlob h]
        )
        (clip.tplCustom)
  imageValue <- case clip.tplImage of
    Nothing -> return []
    Just (TplField (KField i)) -> return [W.VI64 (fromIntegral i)]
    Just (TplConst bytes) -> (: []) . W.VBlob <$> registerBlob bytes
  let strValue rep = case rep of
        TplField (KField i) -> W.VI64 (fromIntegral i)
        TplConst txt -> W.VStr (T.unpack txt)
      present =
        maybe 0 (const W.clipText) (clip.tplText)
          + maybe 0 (const W.clipHtml) (clip.tplHtml)
          + maybe 0 (const W.clipImage) (clip.tplImage)
      files = map (W.VI64 . fromIntegral . (.handle)) (clip.tplFiles)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] ((: []) . strValue) (clip.tplHtml)
          ++ maybe [] ((: []) . strValue) (clip.tplText)
      -- The bound slots BY POSITION, canonical order: a custom pair's
      -- second half, then the image, the html and the text.
      afterCustom = 2 * length (clip.tplCustom) + length (clip.tplFiles)
      afterImage = afterCustom + length imageValue
      afterHtml = afterImage + maybe 0 (const 1) (clip.tplHtml)
      slots =
        [2 * i + 1 | (i, (_, TplField _)) <- zip [0 :: Int ..] (clip.tplCustom)]
          ++ [afterCustom | isTplField (clip.tplImage)]
          ++ [afterImage | isTplField (clip.tplHtml)]
          ++ [afterHtml | isTplField (clip.tplText)]
      bound = sum [2 ^ s | s <- slots] :: Word32
      empty =
        present == 0 && null (clip.tplFiles) && null (clip.tplCustom)
  return
    ( W.txSetDragSource
        w
        present
        (fromIntegral (length (clip.tplFiles)))
        (fromIntegral (length (clip.tplCustom)))
        (if empty then 0 else operationMask ops)
        0
        bound
        values
    )

isTplField :: Maybe (TplRep v) -> Bool
isTplField (Just (TplField _)) = True
isTplField _ = False

-- | The one set_drag_source builder the live, template and keyed forms
-- share: KEYS FIRST, then the reps (set_column_headers' convention).
dragSourceRecord :: Word64 -> [W.Value] -> Clip -> [Op] -> IO Builder
dragSourceRecord w keys clip ops = do
  customValues <-
    concat
      <$> mapM
        ( \(ident, bytes) -> do
            h <- registerBlob bytes
            return [W.VStr (T.unpack (acceptToken ident)), W.VBlob h]
        )
        (clip.custom)
  imageValue <- case clip.image of
    Nothing -> return []
    Just bytes -> (: []) . W.VBlob <$> registerBlob bytes
  let present =
        maybe 0 (const W.clipText) (clip.text)
          + maybe 0 (const W.clipHtml) (clip.html)
          + maybe 0 (const W.clipImage) (clip.image)
      files = map (W.VI64 . fromIntegral . (.handle)) (clip.files)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] (\h -> [W.VStr (T.unpack h)]) (clip.html)
          ++ maybe [] (\t -> [W.VStr (T.unpack t)]) (clip.text)
      empty = present == 0 && null (clip.files) && null (clip.custom)
  return
    ( W.txSetDragSource
        w
        present
        (fromIntegral (length (clip.files)))
        (fromIntegral (length (clip.custom)))
        (if empty then 0 else operationMask ops)
        (fromIntegral (length keys))
        0
        (keys ++ values)
    )

-- | DECLARE that a widget receives drops, performing these operations;
-- naming NONE withdraws it. WHAT it takes is its 'setAccepts' list,
-- which must be declared first — a destination has one vocabulary, not
-- two (docs\/dnd-plan.md D1).
setDropTarget :: Widget -> [Op] -> Build ()
setDropTarget (Widget w) ops =
  emitB (W.txSetDropTarget w (operationMask ops) 0 [])

-- | ONE STAMPED COPY's drag declaration (docs\/dnd-plan.md §4): the
-- template node and the copy's keys, outermost first. The per-row
-- payload an app declares after the row's insert; it overrides the
-- template's own for that copy and follows it through a re-stamp.
setDragSourceAt :: Node -> [Key] -> Clip -> [Op] -> Build ()
setDragSourceAt (Node n) keys clip ops =
  emitBIO (dragSourceRecord n (map keyValue keys) clip ops)

-- | 'setDragSourceAt''s twin: ONE stamped copy receives drops with these
-- operations, taking what the template's 'TplAccepts' names.
setDropTargetAt :: Node -> [Key] -> [Op] -> Build ()
setDropTargetAt (Node n) keys ops =
  emitB (W.txSetDropTarget n (operationMask ops) (fromIntegral (length keys)) (map keyValue keys))

-- | Rows of this live For drag within their own collection
-- (docs\/dnd-plan.md D8): the landing arrives at 'onDrop' on the For's
-- own container — the element 'forEach' returns — and the app confirms
-- with a move.
setReorderable :: Widget -> Bool -> Build ()
setReorderable (Widget w) enabled =
  emitB (W.txSetReorderable w (if enabled then 1 else 0))

-- | Ask the platform for files. THE PICK, NOT THE OPEN — the result
-- carries handles you redeem later (DESIGN.md, File dialogs). The
-- filters are (label, space-separated extensions) pairs, ADVISORY on
-- every platform. The handler fires exactly once and retires with its
-- answer; CANCEL IS THE EMPTY LIST, and one dialog may be live per
-- process.
pickFiles :: [(Text, Text)] -> ([PickedFile] -> IO ()) -> Build ()
pickFiles = pick True

-- | The single-file spelling. The floor always returns a LIST; this
-- only asks the platform for one, so the handler receives zero or one.
pickFile :: [(Text, Text)] -> ([PickedFile] -> IO ()) -> Build ()
pickFile = pick False

pick :: Bool -> [(Text, Text)] -> ([PickedFile] -> IO ()) -> Build ()
pick multiple filters handler = do
  n <- state $ \s ->
    let c = s.bCounters
        next = c.cFileDialog + 1
     in (next, s {bCounters = c {cFileDialog = next}})
  pendB (PFileDialog n handler)
  emitB
    ( W.txShowFileDialog
        0
        n
        (if multiple then 1 else 0)
        (filterValues filters)
    )

-- | Ask the platform WHERE TO SAVE — the picker's twin, on the same
-- request\/result grammar and out of the same one-live-dialog slot; the
-- handler fires exactly once and CANCEL IS 'Nothing'. Read the name you
-- GOT (the handle's own @name@), never the one you asked for: no platform promises
-- the suggested one. WHAT YOU GET BACK OPENS EMPTY
-- (docs\/save-plan.md D1; DESIGN.md).
saveFile :: Text -> [(Text, Text)] -> (Maybe PickedFile -> IO ()) -> Build ()
saveFile suggested filters handler = do
  -- THE PICKER'S COUNTER AND THE PICKER'S TABLE, deliberately: the core
  -- has one dialog id space, one live slot and one retire gate, so a
  -- save minting ids of its own could collide with a pick.
  n <- state $ \s ->
    let c = s.bCounters
        next = c.cFileDialog + 1
     in (next, s {bCounters = c {cFileDialog = next}})
  pendB (PFileDialog n (handler . listToMaybe))
  emitB (W.txShowSaveDialog 0 n (W.VStr (T.unpack suggested)) (filterValues filters))

-- (label, space-separated extensions) pairs, flattened the way the wire
-- carries them.
filterValues :: [(Text, Text)] -> [W.Value]
filterValues = concatMap (\(label, exts) -> [W.VStr (T.unpack label), W.VStr (T.unpack exts)])

-- | Mount a root into the default window; mounting presents.
mount :: Widget -> Build ()
mount (Widget n) = emitB (W.txMount 0 n)

-- | Drop an entry's content now (the field stays authoritative).
clearWidget :: Widget -> Build ()
clearWidget (Widget n) = emitB (W.txWidgetCommand n W.commandClear)

-- | Give this widget the keyboard focus.
focusWidget :: Widget -> Build ()
focusWidget (Widget n) = emitB (W.txWidgetCommand n W.commandFocus)

-- The three text-range verbs (docs\/ranges-plan.md D1). Textarea only.
--
-- A RANGE IS A PAIR OF UTF-8 BYTE OFFSETS, half-open, and HASKELL'S OWN
-- UNIT IS NOT BYTES: a 'String' is a list of 'Char', so @findIndex@ over
-- one counts SCALARS and every offset it returns is wrong for a
-- non-ASCII document, silently. Search the UTF-8 encoding instead —
-- @Data.ByteString.breakSubstring@ over @toLazyByteString . stringUtf8@.

-- | Declare the decorated ranges of a textarea, replacing whatever was
-- declared before; @[]@ is the clear. APP-OWNED AND NEVER TRACKED: the
-- first edit of any kind drops the set, and kaya adjusts no range across
-- an edit (docs\/ranges-plan.md §3).
highlightRanges :: Widget -> [(Int, Int)] -> Build ()
highlightRanges (Widget n) ranges =
  emitB (W.txHighlightRanges n (fromIntegral (length ranges)) (concatMap pair ranges))
  where
    -- One flat Values list read IN PAIRS by the core, start then end;
    -- the count travels beside it and the two must agree.
    pair (start, stop) = [W.VI64 (fromIntegral start), W.VI64 (fromIntegral stop)]

-- | Put the textarea's selection at one range (an empty range is a caret).
-- Same offsets, same validation as 'highlightRanges'. REFUSED WHILE THE USER
-- IS COMPOSING through an input method, in every backend, and the refusal is
-- a no-op rather than an error (docs\/deferred.md).
selectRange :: Widget -> (Int, Int) -> Build ()
selectRange (Widget n) (start, stop) =
  emitB (W.txSelectRange n (fromIntegral start) (fromIntegral stop))

-- | Scroll the textarea so a range is inside the viewport. A pure effect: it
-- moves no state, leaves the selection alone, and undo does not put the
-- scroll position back (undo restores state, not where you were looking).
revealRange :: Widget -> (Int, Int) -> Build ()
revealRange (Widget n) (start, stop) =
  emitB (W.txRevealRange n (fromIntegral start) (fromIntegral stop))

-- | Scroll the For mounted in this container — the widget 'forEach'
-- returns — so the row keyed @key@ tops the viewport, clamped at the end
-- (docs\/scroll-to-plan.md). A pure effect; a key the collection does not
-- hold scrolls nothing.
scrollToRow :: Widget -> Key -> Build ()
scrollToRow (Widget n) key = emitB (W.txScrollToRow n (keyValue key))

-- --- Rich text (docs\/rich-text-plan.md R1) -------------------------
-- EVERY OFFSET IS A UTF-8 BYTE OFFSET into the widget's text
-- (docs\/ranges-units.md §7), and a range is the ranges sugar's
-- @(start, stop)@ pair. A Haskell 'String' is CHARACTERS, so the mirror
-- splices in the byte domain and decodes back.

editSourceName :: EditSource -> Text
editSourceName s = case s of
  User -> "user"
  ImeCommit -> "ime_commit"
  Paste -> "paste"
  NativeUndo -> "native_undo"
  Drop -> "drop"

editSourceOfWire :: Word32 -> EditSource
editSourceOfWire n
  | n == W.editSourceUser = User
  | n == W.editSourceImeCommit = ImeCommit
  | n == W.editSourcePaste = Paste
  | n == W.editSourceNativeUndo = NativeUndo
  | n == W.editSourceDrop = Drop
  | otherwise =
      error
        ( "kaya: text_edited carries edit source "
            ++ show n
            ++ ", which this build does not know"
        )

-- | One paragraph kind; drawn, never stored (docs\/rich-text-plan.md R3).
data Block = Body | Heading1 | Heading2 | Heading3 | Quote | CodeBlock
  deriving (Eq, Show)

blockName :: Block -> Text
blockName b = case b of
  Body -> "body"
  Heading1 -> "heading1"
  Heading2 -> "heading2"
  Heading3 -> "heading3"
  Quote -> "quote"
  CodeBlock -> "code_block"

-- | A document with no runs yet, to mark up.
documentOf :: Text -> Document
documentOf txt = Document txt []

-- THE DOCUMENT COMES LAST, so a declaration composes:
-- @blockRun (13, 24) Heading2 . boldRun (0, 6) $ documentOf text@.

mark :: (Int, Int) -> Text -> MarkValue -> Document -> Document
mark r n v doc = Document doc.text (doc.runs ++ [Run r n v])

-- | A run's marks, suffixed: the plain names are the widget's own acts.
boldRun, italicRun, underlineRun, strikeRun, codeRun ::
  (Int, Int) -> Document -> Document
boldRun r = mark r "bold" (Flag True)
italicRun r = mark r "italic" (Flag True)
underlineRun r = mark r "underline" (Flag True)
strikeRun r = mark r "strike" (Flag True)
codeRun r = mark r "code" (Flag True)

-- | A run's link; 'link' itself is the widget's act.
linkRun :: (Int, Int) -> Text -> Document -> Document
linkRun r url = mark r "link" (Spelled url)

-- | A paragraph's kind; the range covers whole paragraphs or is refused.
blockRun :: (Int, Int) -> Block -> Document -> Document
blockRun r kind = mark r "block" (Spelled (blockName kind))

attrAt :: Document -> Int -> Text -> Maybe MarkValue
attrAt doc byte n =
  (.value)
    <$> listToMaybe
      [ r
        | r <- doc.runs,
          r.name == n,
          fst r.range <= byte,
          byte < snd r.range
      ]

insertEdit :: Int -> Text -> Edit
insertEdit at txt = Edit (at, at) txt [] Nothing

deleteEdit :: (Int, Int) -> Edit
deleteEdit r = Edit r "" [] Nothing

replaceEdit :: (Int, Int) -> Text -> Edit
replaceEdit r txt = Edit r txt [] Nothing

-- | One attribute over the INSERTED text's own offsets.
markEdit :: (Int, Int) -> Text -> MarkValue -> Edit -> Edit
markEdit r n v e = Edit e.range e.inserted (e.runs ++ [Run r n v]) e.source

-- Byte offsets are the core's (docs/ranges-units.md); the wire module
-- decodes inbound Strs itself (docs/traps.md 2026-09-11).

-- | The core's normal form (crates\/kaya\/src\/scene.rs,
-- @RichDoc::normalize@), so the mirror and the core's document spell one
-- string.
normalizeRuns :: [Run] -> [Run]
normalizeRuns rs = List.sortOn (\r -> (fst r.range, r.name)) (concatMap perName names)
  where
    names = List.sort (List.nub (map (.name) rs))
    perName n =
      merge (List.sortOn (fst . (.range)) (foldl paint [] (filter ((== n) . (.name)) rs)))
    paint :: [Run] -> Run -> [Run]
    paint painted run
      | fst run.range >= snd run.range = painted
      | otherwise = concatMap (cut run) painted ++ [run]
    cut :: Run -> Run -> [Run]
    cut run old
      | snd old.range <= fst run.range || fst old.range >= snd run.range = [old]
      | otherwise =
          [spanning old (fst old.range, fst run.range) | fst old.range < fst run.range]
            ++ [spanning old (snd run.range, snd old.range) | snd old.range > snd run.range]
    -- THE RANGE MOVES AND NOTHING ELSE: record UPDATE syntax is out,
    -- since GHC refuses an ambiguous update on a field three records
    -- share (Run, Edit and Format each carry a 'range').
    spanning :: Run -> (Int, Int) -> Run
    spanning r to = Run to r.name r.value
    merge :: [Run] -> [Run]
    merge [] = []
    merge (r : rest) = go r rest
      where
        go acc [] = [acc]
        go acc (next : more)
          | snd acc.range == fst next.range && acc.value == next.value =
              go (spanning acc (fst acc.range, snd next.range)) more
          | otherwise = acc : go next more

-- | The folded document of a @rich@ textarea; empty until the first edit
-- or write.
document :: App -> Widget -> IO Document
document app (Widget n) =
  Map.findWithDefault (documentOf "") n <$> readIORef (app.appDocuments)

-- | The core's own fold rule, over ANY document — a live mirror or a
-- stamped copy's row field (crates\/kaya\/src\/app.rs, @fold_edit@;
-- docs\/rich-text-plan.md §19).
foldEdit :: Edit -> Document -> Document
foldEdit e doc =
      let bytes = utf8Bytes doc.text
          len = length bytes
          ins = utf8Bytes e.inserted
          (start, stop) = e.range
          boundary at = at == len || (bytes !! at) .&. 0xc0 /= 0x80
          shift = length ins - (stop - start)
          moved r to = Run to r.name r.value
          kept =
            concatMap
              ( \r ->
                  [moved r (fst r.range, min (snd r.range) start) | fst r.range < start]
                    ++ [ moved r (max (fst r.range) stop + shift, snd r.range + shift)
                         | snd r.range > stop
                       ]
              )
              doc.runs
          landed = map (\r -> moved r (fst r.range + start, snd r.range + start)) e.runs
       in if start < 0 || start > stop || stop > len || not (boundary start)
            || not (boundary stop)
            then -- A mirror out of step with the core would splice garbage.
              Document e.inserted e.runs
            else
              Document
                (utf8Chars (take start bytes ++ ins ++ drop stop bytes))
                (normalizeRuns (kept ++ landed))

-- | The core's @fold_format@, over any document.
foldFormat :: Format -> Document -> Document
foldFormat act doc
  | fst act.range >= snd act.range = doc
  | otherwise =
      let (start, stop) = act.range
          n = act.name
          moved r to = Run to r.name r.value
          kept =
            concatMap
              ( \r ->
                  if r.name /= n || snd r.range <= start || fst r.range >= stop
                    then [r]
                    else
                      [moved r (fst r.range, start) | fst r.range < start]
                        ++ [moved r (stop, snd r.range) | snd r.range > stop]
              )
              doc.runs
          painted = case act.value of
            Just v -> kept ++ [Run (start, stop) n v]
            Nothing -> kept
       in Document doc.text (normalizeRuns painted)

-- One delivered act, into the live mirror (crates/kaya/src/app.rs,
-- @absorb_edit@ / @absorb_format@).
absorbEdit :: App -> Widget -> Edit -> IO ()
absorbEdit app (Widget n) e =
  modifyIORef'
    (app.appDocuments)
    (Map.alter (Just . foldEdit e . fromMaybe (documentOf "")) n)

absorbFormat :: App -> Widget -> Format -> IO ()
absorbFormat app (Widget n) act =
  modifyIORef'
    (app.appDocuments)
    (Map.alter (Just . foldFormat act . fromMaybe (documentOf "")) n)

-- A stamped copy's edit or format act reaches its ROW's Document field
-- (docs/rich-text-plan.md §19): the node is bound to (collection, field,
-- level) by 'textareaRichBound', and the occurrence's path names the
-- row. A row that is gone has no field to fold into, and that is not a
-- fault.
foldRowDocument :: App -> Node -> [Key] -> (Document -> Document) -> IO ()
foldRowDocument app (Node n) path0 f = do
  let path = map keyValue path0
  binds <- readIORef (app.appDocumentBinds)
  case Map.lookup n binds of
    Nothing -> return ()
    -- [level] Fors up is [level] keys shorter: the innermost copy's own
    -- keys are the trailing ones.
    Just (cid, i, level) ->
      case reverse (take (length path - fromIntegral level) path) of
        [] -> return ()
        (key : revAncestors) ->
          let ancestors = reverse revAncestors
              at = fromIntegral i
              slot vs =
                let doc = case drop at vs of
                      (W.VStr b : _) -> documentOfBlob (BC.pack b)
                      _ -> documentOf ""
                 in take at vs
                      ++ [W.VStr (BC.unpack (documentBlob (f doc)))]
                      ++ drop (at + 1) vs
              onEntry (k, (variant, vs))
                | k == key = (k, (variant, slot vs))
                | otherwise = (k, (variant, vs))
              onInstance inst
                | inst.iPath == ancestors = inst {iEntries = map onEntry (inst.iEntries)}
                | otherwise = inst
           in modifyIORef' (app.appModel) $ \(model, children) ->
                (Map.adjust (map onInstance) cid model, children)

-- | This widget carries attribute runs: 'setDocument', 'applyEdit',
-- 'onEdit'. A textarea edits them; a label draws them read-only
-- (docs\/rich-text-plan.md R8, §15).
setRich :: Widget -> Bool -> Build ()
setRich (Widget n) on = emitB (W.txSetRich n on)

-- | The app owns this textarea's history (docs\/rich-text-plan.md R6, §14):
-- the platform's own stack goes off and Edit>Undo reaches the app through
-- the role item's activation.
setOwnUndo :: Widget -> Bool -> Build ()
setOwnUndo (Widget n) on = emitB (W.txSetOwnUndo n on)

-- | Return in this textarea publishes 'onSubmit' instead of inserting a
-- newline (docs\/submit-plan.md S2); Shift+Return is then the newline.
setSubmits :: Widget -> Bool -> Build ()
setSubmits (Widget n) on = emitB (W.txSetSubmits n on)

-- | Replace a @rich@ textarea's whole document: echoes nothing and, like
-- 'setText', spends the native undo history (docs\/undo-plan.md D7).
--
-- THE MIRROR IS THE APP'S STATE, so this takes the 'App': the seed rides
-- the record's own IO, which 'buildTx' runs as it serializes the batch.
setDocument :: App -> Widget -> Document -> Build ()
setDocument app (Widget n) doc = emitBIO $ do
  modifyIORef' (app.appDocuments) (Map.insert n doc)
  return
    ( W.txSetRichText
        n
        (fromIntegral (length (doc.runs)))
        (runValues (doc.runs))
        (W.VStr (T.unpack (doc.text)))
    )

-- | One edit into a @rich@ textarea: echoes nothing, never resets undo,
-- and is held rather than refused mid-composition (R5). THE MIRROR TAKES
-- IT AS IT IS SENT, so the app's document is ahead of the widget's until
-- a live composition ends (docs\/rich-text-plan.md §7).
applyEdit :: App -> Widget -> Edit -> Build ()
applyEdit app (Widget n) e = emitBIO $ do
  absorbEdit app (Widget n) e
  return
    ( W.txApplyEdit
        n
        (fromIntegral (fst e.range))
        (fromIntegral (snd e.range))
        (fromIntegral (length (e.runs)))
        (runValues (e.runs))
        (W.VStr (T.unpack (e.inserted)))
    )

-- | Format the widget's CURRENT SELECTION through its own act — what a
-- toolbar button sends; the widget answers through 'onFormat'. Over a
-- collapsed selection the attribute is armed for the next keystroke
-- instead. The value is @\"true\"@ for a flag, the URL for @link@.
formatText :: Widget -> Text -> MarkValue -> Build ()
formatText (Widget n) name value =
  emitB
    ( W.txFormatText n 0 0 0 0
        [W.VStr (T.unpack name), W.VStr (T.unpack (markSpelling value))]
    )

-- | The named acts (docs\/rich-text-plan.md §18): 'formatText' with its
-- own name over the widget's selection. A run's mark is 'boldRun' and
-- its siblings, the app-links route declarator 'linkRoute'.
bold :: Widget -> Build ()
bold w = formatText w "bold" (Flag True)

italic :: Widget -> Build ()
italic w = formatText w "italic" (Flag True)

underline :: Widget -> Build ()
underline w = formatText w "underline" (Flag True)

strike :: Widget -> Build ()
strike w = formatText w "strike" (Flag True)

code :: Widget -> Build ()
code w = formatText w "code" (Flag True)

link :: Widget -> Text -> Build ()
link w url = formatText w "link" (Spelled url)

-- | Take an attribute off the widget's current selection.
unformat :: Widget -> Text -> Build ()
unformat (Widget n) name =
  emitB (W.txFormatText n 1 0 0 0 [W.VStr (T.unpack name), W.VStr ""])

-- A ranged act's range in the fold's text: a @block@ covers the whole
-- paragraphs it touches, as the core snaps it.
rangedActBounds :: App -> Word64 -> (Int, Int) -> Text -> IO (Int, Int)
rangedActBounds app n (start, stop) name
  | name /= "block" = return (start, stop)
  | otherwise = do
      docs <- readIORef (app.appDocuments)
      let bytes = utf8Bytes (maybe "" (.text) (Map.lookup n docs))
          len = length bytes
          from = min start len
          to = min stop len
          paraStart = maybe 0 (from -) (elemIndex 10 (reverse (take from bytes)))
          paraEnd = maybe len (to +) (elemIndex 10 (drop to bytes))
      return (paraStart, paraEnd)

-- | One attribute over a BYTE RANGE of the document, the selection left
-- where it is: a document write, echoed by nothing, legal on a rich
-- label, and the fold moves here as 'applyEdit' moves it
-- (docs\/rich-text-plan.md §17). A @block@ covers the range's whole
-- paragraphs, and @block@ with @\"body\"@ takes the kind off.
formatTextRange :: App -> Widget -> (Int, Int) -> Text -> MarkValue -> Build ()
formatTextRange app (Widget n) at name value = emitBIO $ do
  (start, stop) <- rangedActBounds app n at name
  let painted =
        if name == "block" && value == Spelled "body" then Nothing else Just value
  absorbFormat app (Widget n) (Format (start, stop) name painted)
  return
    ( W.txFormatText
        n
        (maybe 1 (const 0) painted)
        1
        (fromIntegral start)
        (fromIntegral stop)
        [ W.VStr (T.unpack name),
          W.VStr (T.unpack (maybe "" markSpelling painted))
        ]
    )

-- | The removal 'formatTextRange' pairs with.
unformatRange :: App -> Widget -> (Int, Int) -> Text -> Build ()
unformatRange app (Widget n) at name = emitBIO $ do
  (start, stop) <- rangedActBounds app n at name
  absorbFormat app (Widget n) (Format (start, stop) name Nothing)
  return
    ( W.txFormatText n 1 1 (fromIntegral start) (fromIntegral stop)
        [W.VStr (T.unpack name), W.VStr ""]
    )

-- | Make the selection's paragraphs @kind@; 'Body' clears.
setBlock :: Widget -> Block -> Build ()
setBlock w kind = formatText w "block" (Spelled (blockName kind))

-- | What an 'OwnUndo' textarea's app can take back right now, and put
-- back: the route reads these (docs\/rich-text-plan.md §14), so a write
-- re-reads Edit>Undo's and Edit>Redo's enablement.
canUndo :: Widget -> Bool -> Build ()
canUndo (Widget n) on = emitB (W.txSetCanUndo n on)

canRedo :: Widget -> Bool -> Build ()
canRedo (Widget n) on = emitB (W.txSetCanRedo n on)

-- | One addressed user edit of a @rich@ textarea; a change handler still
-- fires beside it (docs\/rich-text-plan.md R1). App-registered, the way
-- 'onDraw' is: the handler reads the widget's own 'document'.
onEdit :: App -> Widget -> (Edit -> IO ()) -> IO ()
onEdit app (Widget n) f = modifyIORef' (app.appWidgetEdits) (Map.insert n f)

-- | The user formatted a range; a format over a collapsed caret is
-- pending state and arrives as the next edit's runs, never here.
onFormat :: App -> Widget -> (Format -> IO ()) -> IO ()
onFormat app (Widget n) f = modifyIORef' (app.appWidgetFormats) (Map.insert n f)

-- | A stamped rich copy's edit, with its row's key path outermost first
-- — 'onEdit' one zone over (docs\/rich-text-plan.md §19). The row's
-- Document field has already taken the act when this fires, so the
-- handler reads the ROW and never the widget.
onEditNode :: App -> Node -> ([Key] -> Edit -> IO ()) -> IO ()
onEditNode app (Node n) f = modifyIORef' (app.appNodeEdits) (Map.insert n f)

onFormatNode :: App -> Node -> ([Key] -> Format -> IO ()) -> IO ()
onFormatNode app (Node n) f = modifyIORef' (app.appNodeFormats) (Map.insert n f)

-- | Write a live widget's text: seed an editor's document, re-caption a
-- label. LIVE WIDGETS ONLY — the same write on a template Node is the
-- floor spelling 'setTextProp' (docs\/tpl-props-plan.md F3).
setText :: Widget -> Text -> Build ()
setText = setTextProp

bindText :: Widget -> Signal Text -> Build ()
bindText (Widget w) (Signal s) = emitB (W.txBindText w s)

-- | A container's inter-child gap (main axis, DIP; the normalized default is
-- 8).
setSpacing :: Widget -> Double -> Build ()
setSpacing (Widget w) gap = emitB (W.txSetSpacing w gap)

-- | A container's OWN padding: the DIP between its bounds and its
-- children, uniform on all four sides (docs\/styling-plan.md D3).
-- Containers only, and the ROOT is what says so: a leaf, a negative or
-- a non-finite pad dies at declare time naming the prop. The dynamic
-- path; the declarative spelling is the 'Inset' attr.
setInset :: Widget -> Double -> Build ()
setInset (Widget w) pad = emitB (W.txSetInset w pad)

-- Construction props are a closed GADT indexed by widget class:
-- container-only props on a leaf are type errors before they are scene
-- errors.
data WClass = BoxW | LeafW

-- | A container's cross-axis child placement (the align spec enum; the
-- normalized default is 'AlignStart').
data Align
  = AlignStart
  | AlignCenter
  | AlignEnd
  | AlignStretch
  | AlignBaseline
  deriving (Eq, Show)

alignWire :: Align -> Int64
alignWire AlignStart = 0
alignWire AlignCenter = 1
alignWire AlignEnd = 2
alignWire AlignStretch = 3
alignWire AlignBaseline = 4

-- | The dynamic path; the declarative spelling is the 'Align' attr.
setAlign :: Widget -> Align -> Build ()
setAlign (Widget w) a = emitB (W.txSetAlign w (alignWire a))

-- | A container's arrangement direction: row and column are ONE node
-- this parameterizes, and the creation kind's own is the default
-- (docs\/adaptive-layout-plan.md D1).
data Axis
  = AxisHorizontal
  | AxisVertical
  deriving (Eq, Show)

axisWire :: Axis -> Int64
axisWire AxisHorizontal = fromIntegral W.axisHorizontal
axisWire AxisVertical = fromIntegral W.axisVertical

-- | The user-driven orientation toggle (docs\/adaptive-layout-plan.md
-- D2). Row\/column only; the widget stays what its creation kind made it
-- and only its presentation moves.
setAxis :: Widget -> Axis -> Build ()
setAxis (Widget w) a = emitB (W.txSetAxis w (axisWire a))

-- | A window's named SIZE CLASS (spec enum "size_class"): what
-- 'stackWhen' speaks in place of an author-invented width. 'Compact' is
-- the whole surface today — the platform's own class on iOS, narrower
-- than 600 points everywhere else. An app names a class, it never asks
-- which one the window is.
data SizeClass = Compact

sizeClassWire :: SizeClass -> Int64
sizeClassWire Compact = fromIntegral W.sizeClassCompact

-- | Stack this row's children vertically while the window's SIZE CLASS
-- is the named one, reverting on leaving the class — ONE core-evaluated
-- breakpoint record (docs\/adaptive-layout-plan.md D3). The declarative
-- spelling is the 'StackWhen' attr; taking a 'Widget' is the template
-- zone's refusal, since a breakpoint's setters name live widgets.
stackWhen :: Widget -> SizeClass -> Build ()
stackWhen (Widget w) when =
  emitB
    ( W.txCreateBreakpoint
        0
        (W.VI64 (sizeClassWire when))
        1
        [ W.VI64 (fromIntegral w),
          W.VI64 (fromIntegral W.propAxis),
          W.VI64 (fromIntegral W.axisVertical)
        ]
    )

-- | Lay this grid out in the named number of columns while the window's
-- SIZE CLASS is the named one, restoring the authored count on leaving
-- it (docs\/adaptive-layout-plan.md D6.2). Taking a 'Widget' is the
-- template zone's refusal, as 'stackWhen'\'s is.
columnsWhen :: Widget -> SizeClass -> Int -> Build ()
columnsWhen (Widget w) when columns =
  emitB
    ( W.txCreateBreakpoint
        0
        (W.VI64 (sizeClassWire when))
        1
        [ W.VI64 (fromIntegral w),
          W.VI64 (fromIntegral W.propColumns),
          W.VF64 (fromIntegral columns)
        ]
    )

-- | The role vocabulary (docs/styling-plan.md D4): SEMANTIC EMPHASIS — what a
-- widget MEANS, never how it looks.
data Role
  = -- | An action whose press destroys something. Buttons only.
    Destructive
  | -- | THE primary action, one per dialog's worth of emphasis: the
    -- platform's default-button treatment. Buttons only.
    Prominent
  | -- | A text hierarchy heading — the platform's heading text style AND
    -- the heading trait assistive users skim by. Labels only.
    Heading
  | -- | The heading's counterpart one tier down: the platform's footnote
    -- text, under the content it explains. Labels only.
    Caption
  | -- | An action at low emphasis: a row's accessory (Details, Open).
    -- Buttons only.
    Plain
  | -- | A checkbox drawn as the platform's SWITCH and reporting its
    -- trait (docs\/tasks-s2-plan.md T1): a setting that takes effect at
    -- once. Checkboxes only.
    Switch
  | -- | A label drawn as the platform's LINK, opening its 'Href' through
    -- the platform's own opener (docs\/tasks-s2-plan.md T3). Labels only.
    Link
  deriving (Eq, Show)

roleWire :: Role -> Int64
roleWire Destructive = 1
roleWire Prominent = 2
roleWire Heading = 3
roleWire Caption = 4
roleWire Plain = 5
roleWire Switch = 6
roleWire Link = 7

-- | The dynamic path; the declarative spelling is the 'Role' attr.
setRole :: Widget -> Role -> Build ()
setRole (Widget w) r = emitB (W.txSetRole w (roleWire r))

-- | A widget's accessibility IDENTIFIER: a stable authored key that assistive
-- tooling and UI automation address it by, and which is NEVER spoken.
setA11yId :: Widget -> Text -> Build ()
setA11yId (Widget w) i = emitB (W.txSetA11yId w (T.unpack i))

-- | What an assistive client SPEAKS for a widget. Universal, and deliberately
-- separate from the identifier — an automation key is not a spoken name.
-- Leave it unset to keep whatever the platform derives from the control's own
-- content; setting it OVERRIDES that.
setA11yLabel :: Widget -> Text -> Build ()
setA11yLabel (Widget w) l = emitB (W.txSetA11yLabel w (T.unpack l))

-- | What ACTIVATING this widget does — the platforms' hint (Apple defines it
-- as the result of performing an action; Android carries it as the click
-- action's label). Write a VERB PHRASE.
setA11yHint :: Widget -> Text -> Build ()
setA11yHint (Widget w) h = emitB (W.txSetA11yHint w (T.unpack h))

-- | The SIGNAL-SOURCED forms of the trio, spelled as 'bindText' is.
bindA11yId, bindA11yLabel, bindA11yHint :: Widget -> Signal Text -> Build ()
bindA11yId (Widget w) (Signal s) = emitB (W.txBindA11yId w s)
bindA11yLabel (Widget w) (Signal s) = emitB (W.txBindA11yLabel w s)
bindA11yHint (Widget w) (Signal s) = emitB (W.txBindA11yHint w s)

-- | A widget's HELP TEXT: one short sentence saying what the control is
-- or does (docs/tooltip-plan.md T1). Universal. The platform picks the
-- surface — a tooltip on the desktops, nothing visible on the iPhone —
-- and hands the text to its assistive reader; an authored hint wins the
-- hint slot (T3).
setHelp :: Widget -> Text -> Build ()
setHelp (Widget w) h = emitB (W.txSetHelp w (T.unpack h))

bindHelp :: Widget -> Signal Text -> Build ()
bindHelp (Widget w) (Signal s) = emitB (W.txBindHelp w s)

-- | The PROMPT a text field shows while it is empty
-- (docs/search-plan.md S3): the platform's own placeholder, never part
-- of the text and never emitted. Entry, textarea and search only,
-- checked at the root.
setPlaceholder :: Widget -> Text -> Build ()
setPlaceholder (Widget w) v = emitB (W.txSetPlaceholder w (T.unpack v))

bindPlaceholder :: Widget -> Signal Text -> Build ()
bindPlaceholder (Widget w) (Signal s) = emitB (W.txBindPlaceholder w s)

-- | The DESTINATION a 'Link' label opens (docs\/tasks-s2-plan.md T3): the
-- platform's own opener takes it and nothing is emitted.
setHref :: Widget -> Text -> Build ()
setHref (Widget w) v = emitB (W.txSetHref w (T.unpack v))

bindHref :: Widget -> Signal Text -> Build ()
bindHref (Widget w) (Signal s) = emitB (W.txBindHref w s)

data Attr (c :: WClass) where
  -- | This widget's flex weight — any widget class.
  Grow :: Double -> Attr c
  -- | Whether this widget spans its container's cross axis — a column's
  -- width, a row's height — whatever the container's 'Align'
  -- (docs\/layout-knobs-plan.md §1). Any widget class, like 'Grow';
  -- unset, the kind's own default holds.
  Fill :: Bool -> Attr c
  -- | THE GRID THAT FITS (docs\/layout-knobs-plan.md §3): as many columns
  -- as fit this grid's width at that many DIP each, sharing the extra.
  -- Grids only; an explicit 'columnsWhen' still wins while its class holds.
  ColumnsAuto :: Double -> Attr 'BoxW
  -- | A ROW THAT FLOWS (docs\/layout-knobs-plan.md §2): the children keep
  -- their natural size and move onto the next line when the row runs out
  -- of width, leading-aligned, the row's 'Spacing' on both axes. Rows
  -- only — the root refuses it elsewhere, as it does 'StackWhen'.
  Wrap :: Bool -> Attr 'BoxW
  -- | This container's inter-child gap (main axis, DIP; the normalized
  -- default is 8).
  Spacing :: Double -> Attr 'BoxW
  -- | This container's own padding, between its bounds and its children — the
  -- window inset one level down.
  Inset :: Double -> Attr 'BoxW
  -- | This container's cross-axis child placement. Containers only,
  -- held by the index like 'Spacing'.
  Align :: Align -> Attr 'BoxW
  -- | Stack this row's children vertically while the window's size
  -- class is the named one. Containers only, and LIVE ZONE ONLY —
  -- 'TplAttr' has no counterpart.
  StackWhen :: SizeClass -> Attr 'BoxW
  -- | This widget's accessibility identifier — any widget class, like
  -- 'Grow': the two accessibility props are universal, so the index
  -- must not narrow them. EVERY STR PROP IS A PAIR, the constant and
  -- the @*Bound@ twin over a signal: one class-polymorphic constructor
  -- cannot infer a bare literal (docs/deferred.md, the Haskell
  -- text-surface entry), which is what 'SBadge'\/'SBadgeBound' already
  -- spelled this way.
  A11yId :: Text -> Attr c
  A11yIdBound :: Signal Text -> Attr c
  -- | What an assistive client speaks for this widget — any widget
  -- class, for the same reason.
  A11yLabel :: Text -> Attr c
  A11yLabelBound :: Signal Text -> Attr c
  -- | What ACTIVATING this widget does. Leaf-class only, unlike the
  -- other two: a hint needs an activation to describe, and the root
  -- admits it on button, checkbox, select and radio alone.
  A11yHint :: Text -> Attr 'LeafW
  A11yHintBound :: Signal Text -> Attr 'LeafW
  -- | This widget's HELP TEXT — any widget class, as the two a11y props
  -- are: one short sentence saying what the control is or does.
  Help :: Text -> Attr c
  HelpBound :: Signal Text -> Attr c
  -- | This widget carries attribute runs (docs\/rich-text-plan.md R1):
  -- 'setDocument', 'applyEdit', 'onEdit'. A textarea edits them; a label
  -- draws them read-only (R8, §15). The root refuses it elsewhere.
  Rich :: Bool -> Attr 'LeafW
  -- | The app owns this textarea's undo history
  -- (docs\/rich-text-plan.md R6, §14). Textarea only.
  OwnUndo :: Bool -> Attr 'LeafW
  -- | Return in this textarea publishes 'onSubmit' and Shift+Return
  -- inserts the newline (docs\/submit-plan.md S2). Textarea only: an entry
  -- and a search field submit on Return with nothing to declare.
  Submits :: Bool -> Attr 'LeafW
  -- | The PROMPT this field shows while its text is empty
  -- (docs\/search-plan.md S3). Entry, textarea and search only; the root
  -- refuses it elsewhere, and an empty one by name.
  Placeholder :: Text -> Attr 'LeafW
  PlaceholderBound :: Signal Text -> Attr 'LeafW
  -- | The DESTINATION this 'Link' label opens
  -- (docs\/tasks-s2-plan.md T3): the platform's own opener takes it, and
  -- nothing is emitted.
  Href :: Text -> Attr 'LeafW
  HrefBound :: Signal Text -> Attr 'LeafW
  -- | A date picker's inclusive lower bound (docs/datetime-plan.md D4);
  -- a pick past it lands on the bound.
  MinDate :: Day -> Attr 'LeafW
  -- | A date picker's inclusive upper bound.
  MaxDate :: Day -> Attr 'LeafW
  -- | A time picker's minute granularity: 1, 5, 10, 15 or 30 (D3).
  MinuteStep :: Int -> Attr 'LeafW
  -- | The granularity a slider's thumb rests on: min + k * step
  -- (docs\/slider-plan.md S1). Divides the range evenly; 0 is continuous.
  Step :: Double -> Attr 'LeafW
  -- | The distance between a slider's drawn ticks, in value units
  -- (docs\/slider-plan.md S5): divides the range evenly, a multiple of the
  -- step when one is declared; 0 draws none.
  TickSpacing :: Double -> Attr 'LeafW
  -- | What this widget MEANS (docs/styling-plan.md D4) — semantic emphasis,
  -- never appearance.
  Role :: Role -> Attr 'LeafW
  -- | What this widget takes from a paste — the closed kinds by name
  -- ('acceptText' and friends) plus any custom format ids.
  Accepts :: [Text] -> Attr c
  -- | What this widget hands over when dragged, and the operations it
  -- allows (docs\/dnd-plan.md D1). 'setDragSource' re-declares it.
  Draggable :: Clip -> [Op] -> Attr c
  -- | This widget receives drops, performing these operations; what it
  -- TAKES is its 'Accepts' list, which must be declared first.
  DropTarget :: [Op] -> Attr c

applyAttr :: Attr c -> Widget -> Build ()
applyAttr (Grow weight) w = setGrow w weight
applyAttr (Fill on) w = setFill w on
applyAttr (ColumnsAuto minWidth) w = setColumnsAuto w minWidth
applyAttr (Wrap on) w = setWrap w on
applyAttr (Spacing gap) w = setSpacing w gap
applyAttr (Inset pad) w = setInset w pad
applyAttr (Align a) w = setAlign w a
applyAttr (StackWhen when) w = stackWhen w when
applyAttr (A11yId i) w = setA11yId w i
applyAttr (A11yIdBound sig) w = bindA11yId w sig
applyAttr (A11yLabel l) w = setA11yLabel w l
applyAttr (A11yLabelBound sig) w = bindA11yLabel w sig
applyAttr (A11yHint h) w = setA11yHint w h
applyAttr (A11yHintBound sig) w = bindA11yHint w sig
applyAttr (Help h) w = setHelp w h
applyAttr (HelpBound sig) w = bindHelp w sig
applyAttr (Rich on) w = setRich w on
applyAttr (OwnUndo on) w = setOwnUndo w on
applyAttr (Submits on) w = setSubmits w on
applyAttr (Placeholder p) w = setPlaceholder w p
applyAttr (PlaceholderBound sig) w = bindPlaceholder w sig
applyAttr (Href u) w = setHref w u
applyAttr (HrefBound sig) w = bindHref w sig
applyAttr (MinDate d) (Widget n) =
  let (y, m, dd) = toGregorian d
   in emitB (W.txSetMinDate n (fromIntegral y) m dd)
applyAttr (MaxDate d) (Widget n) =
  let (y, m, dd) = toGregorian d
   in emitB (W.txSetMaxDate n (fromIntegral y) m dd)
applyAttr (MinuteStep minutes) (Widget n) =
  emitB (W.txSetMinuteStep n (fromIntegral minutes))
applyAttr (Step step) (Widget n) = emitB (W.txSetStep n step)
applyAttr (TickSpacing spacing) (Widget n) = emitB (W.txSetTickSpacing n spacing)
applyAttr (Role r) w = setRole w r
applyAttr (Accepts kinds) w = setAccepts w kinds
applyAttr (Draggable clip ops) w = setDragSource w clip ops
applyAttr (DropTarget ops) w = setDropTarget w ops

withAttrs :: [Attr c] -> Build Widget -> Build Widget
withAttrs attrs act = do
  w <- act
  mapM_ (`applyAttr` w) attrs
  return w

-- One name, both arities — `row [kids]` and `row [Grow 2] [kids]`
-- dispatch on the RESULT type. LIVE ZONE ONLY: an 'Attr' list in
-- template position has no instance, since template props take SOURCES.
class RowCol a r where
  rowish :: Word32 -> [a] -> r

instance (a ~ Build Widget, b ~ Widget) => RowCol a (Build b) where
  rowish = containerOf

-- The wall where someone walks into it: `row [...]` inside a forEach
-- body is the natural thing to write. GHC prints this instead, and the
-- instance body is unreachable because selecting it IS the error.
instance
  ( TypeError
      ( 'Text "kaya: a template row is `rowOf` and a template column is `columnOf`."
          ':$$: 'Text "row/column build in the LIVE zone (Build Widget); the template"
          ':$$: 'Text "zone's containers take Nodes, so they carry their own names."
          ':$$: 'Text "    forEach items $ do { … ; _ <- rowOf [label element, pure b] ; … }"
      ),
    a ~ Tpl Node,
    b ~ Node
  ) =>
  RowCol a (Tpl b)
  where
  rowish = containerOf

instance (a ~ Attr 'BoxW, k ~ Build Widget, r ~ Build Widget) => RowCol a ([k] -> r) where
  rowish kind attrs = withAttrs attrs . containerOf kind

row :: (RowCol a r) => [a] -> r
row = rowish W.kindRow

column :: (RowCol a r) => [a] -> r
column = rowish W.kindColumn

-- | A vertical scroll viewport over EXACTLY ONE child — the signature
-- says so (the scene enforces it too): @scroll [Grow 1] (column
-- [...])@. Give it 'Grow' so the enclosing track CONSTRAINS it — an
-- unconstrained viewport hugs its content and nothing overflows.
scroll :: [Attr 'BoxW] -> Build Widget -> Build Widget
scroll attrs child = withAttrs attrs (containerOf W.kindScroll [child])

-- | A grid from its children, laid out row-major into N columns — each column
-- takes its NATURAL width, aligned across rows (the thing nested rows cannot
-- express).
grid :: Int -> [Build Widget] -> Build Widget
grid = gridWith

gridWith :: (Declare m) => Int -> [m (El m)] -> m (El m)
gridWith columns children = do
  handles <- sequence children
  parent <- widget W.kindGrid
  setColumns parent columns
  mapM_ (addChild parent) handles
  return parent

-- | A LABELLED ROW (docs\/forms-plan.md): the first argument names the one
-- control the children declare, with an optional trailing button after
-- it. A column of nothing but these renders as the platform's form.
labeled :: Text -> [Build Widget] -> Build Widget
labeled name children = labeledWith (labelText name) children

-- | 'labeled' with the name from a signal.
labeledBound :: Signal Text -> [Build Widget] -> Build Widget
labeledBound name children = labeledWith (labelBound name) children

labeledWith :: Build Widget -> [Build Widget] -> Build Widget
labeledWith name children = containerOf W.kindLabeled (name : children)

-- | A spacer: PURE SUGAR for an empty grown column — it consumes the
-- leftover main-axis space between its siblings. In EITHER zone.
spacer :: (Declare m) => m (El m)
spacer = do
  w <- widget W.kindColumn
  setGrow w 1.0
  return w

-- The leaf half of the same idiom: every leaf constructor's result is
-- either the widget or a function awaiting its attr list.
class LeafArgs r where
  leafish :: Build Widget -> r

instance (b ~ Widget) => LeafArgs (Build b) where
  leafish = id

instance (a ~ Attr 'LeafW, r ~ Build Widget) => LeafArgs ([a] -> r) where
  leafish act attrs = withAttrs attrs act

bindChecked :: Widget -> Signal Bool -> Build ()
bindChecked (Widget w) (Signal s) = emitB (W.txBindChecked w s)

-- | Bind a slider's position to a float signal — the programmatic write
-- path (property writes never echo an occurrence, so a handler's own
-- writes cannot loop back at it).
bindValue :: Widget -> Signal Double -> Build ()
bindValue (Widget w) (Signal s) = emitB (W.txBindValue w s)

-- | Bind an image's source to a Blob signal.
bindSource :: Widget -> Signal BS.ByteString -> Build ()
bindSource (Widget w) (Signal s) = emitB (W.txBindSource w s)

containerOf :: (Declare m) => Word32 -> [m (El m)] -> m (El m)
containerOf kind children = do
  handles <- sequence children
  parent <- widget kind
  mapM_ (addChild parent) handles
  return parent

buttonOn :: (LeafArgs r) => Text -> IO () -> r
buttonOn txt handler = leafish $ do
  w@(Widget n) <- widget W.kindButton
  setText w txt
  pendB (PClick n handler)
  return w

-- The handler-free siblings, with the event slot empty. THE LEAVES THAT
-- STAND IN BOTH ZONES are exactly the ones whose arguments are the same
-- in both — a constant caption, or nothing.
class BothZones r where
  bothish :: (forall m. Declare m => m (El m)) -> r

instance (b ~ Widget) => BothZones (Build b) where
  bothish act = act

instance (b ~ Node) => BothZones (Tpl b) where
  bothish act = act

instance (a ~ Attr 'LeafW, r ~ Build Widget) => BothZones ([a] -> r) where
  bothish act attrs = withAttrs attrs act

captionedButton :: (Declare m) => Text -> m (El m)
captionedButton txt = do
  w <- widget W.kindButton
  setTextProp w txt
  return w

button :: (BothZones r) => Text -> r
button txt = bothish (captionedButton txt)

-- | An uncontrolled single-line field, in either zone. Handler-free by
-- construction: the field owns its text and reports each edit. A
-- template copy that should OPEN holding the row's own text is
-- 'entryBound'.
entry :: (BothZones r) => r
entry = bothish (widget W.kindEntry)

entryOn :: (LeafArgs r) => (Text -> IO ()) -> r
entryOn handler = leafish $ do
  w@(Widget n) <- widget W.kindEntry
  pendB (PChange n handler)
  return w

-- | A multi-line editor, in either zone: the entry's uncontrolled
-- contract over the platform's real multi-line control.
textarea :: (BothZones r) => r
textarea = bothish (widget W.kindTextarea)

-- | A multi-line text editor with its change handler co-located:
-- the entry's uncontrolled contract over the platform's real
-- multi-line editor.
textareaOn :: (LeafArgs r) => (Text -> IO ()) -> r
textareaOn handler = leafish $ do
  w@(Widget n) <- widget W.kindTextarea
  pendB (PChange n handler)
  return w

-- | A search field, in either zone: the entry's uncontrolled contract
-- under the platform's search chrome (docs/search-plan.md), filtering on
-- every keystroke. The clear affordance arrives as a change with @""@.
search :: (BothZones r) => r
search = bothish (widget W.kindSearch)

-- | A search field with its change handler co-located.
searchOn :: (LeafArgs r) => (Text -> IO ()) -> r
searchOn handler = leafish $ do
  w@(Widget n) <- widget W.kindSearch
  pendB (PChange n handler)
  return w

-- | A labeled checkbox with its toggle handler co-located.
checkboxOn :: (LeafArgs r) => Text -> (Bool -> IO ()) -> r
checkboxOn txt handler = leafish $ do
  w@(Widget n) <- widget W.kindCheckbox
  setText w txt
  pendB (PToggle n handler)
  return w

-- | A date picker over civil dates holding @day@, with its pick handler
-- co-located (docs/datetime-plan.md): the compact field that opens the
-- platform's calendar. UNCONTROLLED — the control owns its value and
-- reports each COMMITTED pick. 'MinDate' and 'MaxDate' are the range.
datePickerOn :: (LeafArgs r) => Day -> (Day -> IO ()) -> r
datePickerOn day handler = leafish $ do
  w@(Widget n) <- widget W.kindDatePicker
  let (y, m, d) = toGregorian day
  emitB (W.txSetDate n (fromIntegral y) m d)
  pendB (PDate n handler)
  return w

-- | A date picker whose VALUE follows a signal — the programmatic write
-- path; property writes never echo.
datePickerBoundOn :: (LeafArgs r) => Signal Day -> (Day -> IO ()) -> r
datePickerBoundOn (Signal s) handler = leafish $ do
  w@(Widget n) <- widget W.kindDatePicker
  emitB (W.txBindDate n s)
  pendB (PDate n handler)
  return w

-- | A time picker over civil times: hours and minutes, no seconds.
-- 'MinuteStep' is the granularity and a pick snaps to it.
timePickerOn :: (LeafArgs r) => TimeOfDay -> (TimeOfDay -> IO ()) -> r
timePickerOn t handler = leafish $ do
  w@(Widget n) <- widget W.kindTimePicker
  emitB (W.txSetTime n (todHour t) (todMin t))
  pendB (PTime n handler)
  return w

-- | A time picker whose value follows a signal.
timePickerBoundOn :: (LeafArgs r) => Signal TimeOfDay -> (TimeOfDay -> IO ()) -> r
timePickerBoundOn (Signal s) handler = leafish $ do
  w@(Widget n) <- widget W.kindTimePicker
  emitB (W.txBindTime n s)
  pendB (PTime n handler)
  return w

-- | A progress bar: display-only, like label and image — the
-- determinate fraction (0..=1).
progress :: (LeafArgs r) => Double -> r
progress fraction = leafish $ do
  w <- widget W.kindProgress
  let (Widget n) = w
  emitB (W.txSetValue n fraction)
  return w

-- | A progress bar in the platform's activity mode (no fraction), in
-- either zone — with no fraction there is nothing to source, so this is
-- one of the constructors whose two zones take the same nothing.
progressIndeterminate :: (BothZones r) => r
progressIndeterminate =
  bothish $ do
    w <- widget W.kindProgress
    setIndeterminate w True
    return w

-- | A slider over min..max at value, with its change handler
-- co-located.
sliderOn :: (LeafArgs r) => Double -> Double -> Double -> (Double -> IO ()) -> r
sliderOn lo hi value handler = leafish $ do
  w@(Widget n) <- widget W.kindSlider
  emitB (W.txSetMin n lo)
  emitB (W.txSetMax n hi)
  emitB (W.txSetValue n value)
  pendB (PValue n handler)
  return w

-- | A slider whose POSITION follows a float signal, with its change handler
-- co-located: 'sliderOn' with the value bound instead of constant.
sliderBoundOn :: (LeafArgs r) => Double -> Double -> Signal Double -> (Double -> IO ()) -> r
sliderBoundOn lo hi sig handler = leafish $ do
  w@(Widget n) <- widget W.kindSlider
  emitB (W.txSetMin n lo)
  emitB (W.txSetMax n hi)
  bindValue w sig
  pendB (PValue n handler)
  return w

-- | A dropdown select over fixed options — each option becomes a label
-- child (labels only, scene-checked) — at the given initial 0-based
-- index (domain-checked at the root), with its pick handler co-located:
-- the handler receives each USER pick's new index (programmatic writes
-- never echo).
selectOn :: (LeafArgs r) => [Text] -> Int -> (Int -> IO ()) -> r
selectOn options selected handler = leafish $ do
  w@(Widget n) <- widget W.kindSelect
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setText o optionText
        addChild w o
    )
    options
  emitB (W.txSetValue n (fromIntegral selected))
  pendB (PValue n (handler . round))
  return w

-- | A radio group over fixed options — the choice contract
-- ('selectOn') in its inline presentation: same option children,
-- same 0-based index, same pick handler.
radioOn :: (LeafArgs r) => [Text] -> Int -> (Int -> IO ()) -> r
radioOn options selected handler = leafish $ do
  w@(Widget n) <- widget W.kindRadio
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setText o optionText
        addChild w o
    )
    options
  emitB (W.txSetValue n (fromIntegral selected))
  pendB (PValue n (handler . round))
  return w

-- | A label with a CONSTANT caption, in either zone — 'button''s shape
-- one kind over: the argument is the same in both, so a stamped
-- constant label needs no source and no ascription (the addressable
-- spellings are 'labelBound' live and 'label' in a template).
labelText :: (BothZones r) => Text -> r
labelText txt = bothish $ do
  w <- widget W.kindLabel
  setTextProp w txt
  return w

labelBound :: (LeafArgs r) => Signal Text -> r
labelBound sig = leafish $ do
  w <- widget W.kindLabel
  bindText w sig
  return w

-- | A label wearing 'Heading', in one word (the h1 tradition): the
-- platform's heading text style AND the trait assistive users skim by,
-- and on a grouped screen the section-header seat.
headingText :: (LeafArgs r) => Text -> r
headingText txt = leafish $ do
  w <- labelText txt
  setRole w Heading
  return w

-- | 'headingText' with the text bound, as 'labelBound' is to 'labelText'.
headingBound :: (LeafArgs r) => Signal Text -> r
headingBound sig = leafish $ do
  w <- labelBound sig
  setRole w Heading
  return w

-- | A label wearing 'Caption': the platform's footnote tier under the
-- content it explains, and the section-footer seat. The heading's
-- counterpart.
captionText :: (LeafArgs r) => Text -> r
captionText txt = leafish $ do
  w <- labelText txt
  setRole w Caption
  return w

-- | 'captionText' with the text bound.
captionBound :: (LeafArgs r) => Signal Text -> r
captionBound sig = leafish $ do
  w <- labelBound sig
  setRole w Caption
  return w

-- | An image displaying constant encoded bytes (PNG, JPEG, ...): the toolkit
-- decodes natively, and decode failure renders the placeholder, never a
-- crash.
imageBytes :: (LeafArgs r) => BS.ByteString -> r
imageBytes bytes = leafish $ do
  w@(Widget n) <- widget W.kindImage
  emitBIO (W.txSetSource n <$> registerBlob bytes)
  return w

-- | The ASSET form of the source slot: the same image, with the picture
-- NAMED rather than read. THE BYTES NEVER ENTER THIS GUEST'S HEAP: the
-- core clones one refcount into the blob table.
imageAsset :: (LeafArgs r) => Asset -> r
imageAsset src = leafish $ do
  w@(Widget n) <- widget W.kindImage
  emitBIO (W.txSetSource n <$> R.assetBlob src)
  return w

-- | An image whose source follows a Blob signal.
imageBound :: (LeafArgs r) => Signal BS.ByteString -> r
imageBound sig = leafish $ do
  w <- widget W.kindImage
  bindSource w sig
  return w

-- THE CANVAS (docs/canvas-plan.md §2.2): 'DrawOp' holds one opcode and
-- its operands already encoded, which is what the wire carries anyway.

-- | The paint ROLE an op names. Never RGB: the roles resolve in the core
-- per appearance (§3.4).
data Paint = Series | SeriesFill | Grid | Axis | Ground

paintWire :: Paint -> Int64
paintWire p = fromIntegral $ case p of
  Series -> W.paintSeries
  SeriesFill -> W.paintSeriesFill
  Grid -> W.paintGrid
  Axis -> W.paintAxis
  Ground -> W.paintGround

-- | Which way a fill resolves its own crossings.
data FillRule = Nonzero | EvenOdd

fillRuleWire :: FillRule -> Int64
fillRuleWire r = fromIntegral $ case r of
  Nonzero -> W.fillRuleNonzero
  EvenOdd -> W.fillRuleEvenOdd

-- | SVG's @text-anchor@: which end of the run sits at the anchor point.
-- Spelled @Anchor*@ because @AlignStart@ and @AlignEnd@ are 'Align''s.
data TextAlign = AnchorStart | AnchorMiddle | AnchorEnd

textAlignWire :: TextAlign -> Int64
textAlignWire a = fromIntegral $ case a of
  AnchorStart -> W.textAlignStart
  AnchorMiddle -> W.textAlignMiddle
  AnchorEnd -> W.textAlignEnd

-- | SVG's @dominant-baseline@: which horizontal line of the run sits at
-- the anchor point.
data TextBaseline
  = BaselineAlphabetic
  | BaselineMiddle
  | BaselineTop
  | BaselineBottom

textBaselineWire :: TextBaseline -> Int64
textBaselineWire b = fromIntegral $ case b of
  BaselineAlphabetic -> W.textBaselineAlphabetic
  BaselineMiddle -> W.textBaselineMiddle
  BaselineTop -> W.textBaselineTop
  BaselineBottom -> W.textBaselineBottom

drawOp :: Word32 -> [W.Value] -> DrawOp
drawOp code operands = DrawOp (W.VI64 (fromIntegral code) : operands)

-- | Start a subpath at (x, y).
moveTo :: Double -> Double -> DrawOp
moveTo x y = drawOp W.drawOpMoveTo [W.VF64 x, W.VF64 y]

-- | Extend the current subpath to (x, y).
lineTo :: Double -> Double -> DrawOp
lineTo x y = drawOp W.drawOpLineTo [W.VF64 x, W.VF64 y]

-- | Close the current subpath.
close :: DrawOp
close = drawOp W.drawOpClose []

-- | 'moveTo' the first point and 'lineTo' the rest — the chart's own
-- shape, spelled once.
polyline :: [(Double, Double)] -> [DrawOp]
polyline points =
  [if i == (0 :: Int) then moveTo x y else lineTo x y | (i, (x, y)) <- zip [0 ..] points]

-- | Stroke the built path and clear it. The width is in
-- device-independent points and does NOT carry the viewbox stretch, so a
-- 1pt gridline is 1pt at every canvas size (§3.2).
stroke :: Paint -> Double -> DrawOp
stroke paint width = drawOp W.drawOpStroke [W.VI64 (paintWire paint), W.VF64 width]

-- | Fill the built path and clear it.
fill :: Paint -> FillRule -> DrawOp
fill paint rule =
  drawOp W.drawOpFill [W.VI64 (paintWire paint), W.VI64 (fillRuleWire rule)]

-- | Select the face for subsequent text ops. The asset is an ordinary
-- asset name; @""@ is kaya's own embedded default face, which is why a
-- canvas can always draw text (§4.2). The size is in device-independent
-- points.
font :: Text -> Double -> Int64 -> DrawOp
font src size weight =
  drawOp W.drawOpFont [W.VStr (T.unpack src), W.VF64 size, W.VI64 weight]

-- | Draw ONE LINE with its anchor at (x, y). A line break in the string
-- is refused by the core (§3.3).
text :: Double -> Double -> Text -> Paint -> TextAlign -> TextBaseline -> DrawOp
text x y s paint align baseline =
  drawOp
    W.drawOpText
    [ W.VF64 x,
      W.VF64 y,
      W.VI64 (paintWire paint),
      W.VI64 (textAlignWire align),
      W.VI64 (textBaselineWire baseline),
      W.VStr (T.unpack s)
    ]

-- One drawing, framed: KEYS FIRST, then the op stream — TX 46's Values
-- order (docs/canvas-plan.md §3.1).
drawingRecord :: Word64 -> [W.Value] -> Viewbox -> [DrawOp] -> Builder
drawingRecord n keys (Viewbox w h) ops =
  W.txSetDrawing
    n
    (W.VF64 w)
    (W.VF64 h)
    (fromIntegral (length flat))
    (fromIntegral (length keys))
    (keys ++ flat)
  where
    flat = concat [vs | DrawOp vs <- ops]

-- | A drawing surface, and the whole drawing with it: the op list
-- replaces whatever was declared before, never patches it. The viewbox
-- is the coordinate system the ops are written in AND the canvas's
-- natural size in points (§3.2).
canvas :: (LeafArgs r) => Viewbox -> [DrawOp] -> r
canvas vb ops = leafish $ do
  w@(Widget n) <- widget W.kindCanvas
  emitB (drawingRecord n [] vb ops)
  return w

-- | THIS CANVAS REFUSES COERCION: it draws at its viewbox and is placed
-- in whatever track layout gives it (docs\/canvas-plan.md §3.2.1). A
-- canvas that declares none of 'fixed', 'onDraw' and 'onTick' is
-- @scale@.
fixed :: Widget -> Build ()
fixed (Widget w) = emitB (W.txSetSizePolicy w W.sizePolicyFixed)

-- | THIS CANVAS'S DRAWING IS A FUNCTION OF ITS SIZE (docs\/canvas-plan.md
-- §3.2.1): registering IS the declaration, so this also puts the policy
-- on the wire, and the size handed over IS the drawing's viewbox. The
-- ask never reaches the guest as an occurrence — 'dispatchLoop' answers
-- it in a transaction the BINDING opens (tools\/check-ambient-tx.py).
-- LIVE CANVASES ONLY; the argument type is the refusal.
onDraw :: App -> Widget -> (Viewbox -> [DrawOp]) -> IO ()
onDraw app w f = registerDraw app w W.sizePolicyRedraw (\size _ -> f size)

-- | The same, on the platform's FRAME CLOCK: the function is handed the
-- assigned size and the frame's time in seconds; a ticking canvas is
-- asked as a plain redraw once before its first frame and answers at
-- time 0. THE TIME IS THE PLATFORM'S — a guest that reads its own clock
-- re-imports the frame jitter frame times exist to remove.
onTick :: App -> Widget -> (Viewbox -> Double -> [DrawOp]) -> IO ()
onTick app w f = registerDraw app w W.sizePolicyTick f

-- REGISTERING AND DECLARING ARE ONE ACT: a handler without its policy
-- record is a drawing function nothing ever calls (docs/canvas-plan.md
-- §3.2.1's ruling 1). The handler is widened HERE, so the answer path
-- never asks which policy it holds.
registerDraw :: App -> Widget -> Word32 -> (Viewbox -> Double -> [DrawOp]) -> IO ()
registerDraw app (Widget n) policy f = do
  modifyIORef' (app.appDraws) (Map.insert n f)
  submitTx app (emitB (W.txSetSizePolicy n policy))

-- One Str prop's three generated emitters: const, signal, element.
data StrProp = StrProp
  { strConst :: Word64 -> String -> Builder, -- internal; the wire's own spelling, T.unpack'd at every call
    strSignal :: Word64 -> Word64 -> Builder,
    strElement :: Word64 -> Word32 -> Word32 -> Builder
  }

textProp, a11yIdProp, a11yLabelProp, a11yHintProp, helpProp, placeholderProp, hrefProp :: StrProp
textProp = StrProp W.txSetText W.txBindText W.txBindTextElement
a11yIdProp = StrProp W.txSetA11yId W.txBindA11yId W.txBindA11yIdElement
a11yLabelProp = StrProp W.txSetA11yLabel W.txBindA11yLabel W.txBindA11yLabelElement
a11yHintProp = StrProp W.txSetA11yHint W.txBindA11yHint W.txBindA11yHintElement
helpProp = StrProp W.txSetHelp W.txBindHelp W.txBindHelpElement
placeholderProp = StrProp W.txSetPlaceholder W.txBindPlaceholder W.txBindPlaceholderElement
hrefProp = StrProp W.txSetHref W.txBindHref W.txBindHrefElement

-- | What a template Str prop can bind to: a constant, a signal, or the
-- ROW'S OWN field. Named for the prop's VALUE TYPE, the wire's
-- @ValueType::Str@.
--
-- THE CONSTANT ARM IS HERE FOR THE CONSTRUCTORS ALONE — 'label',
-- 'buttonBound' and kin, whose Rust twin takes a @&str@ the same way
-- (@impl From<&str> for TplSource<StrKind>@). The template PROPS carry
-- their three arms as separate 'TplAttr' constructors instead, since a
-- class-polymorphic one cannot infer a bare literal, and a constant
-- caption has 'labelText' and its both-zones siblings, which can
-- (docs/deferred.md, the Haskell text-surface entry).
class TplStrSource s where
  bindStrSource :: StrProp -> Node -> s -> Tpl ()

instance TplStrSource Text where
  bindStrSource p (Node n) txt = emitT (p.strConst n (T.unpack txt))

instance TplStrSource (Signal Text) where
  bindStrSource p (Node n) (Signal s) = emitT (p.strSignal n s)

-- The LEVEL IS 0, as it is in the four bind*Field binders: reaching
-- past the innermost For has no sugar spelling in this binding.
instance TplStrSource (KField Text) where
  bindStrSource p (Node n) (KField i) = emitT (p.strElement n 0 i)

-- | The text prop's binder, which every text-carrying constructor in
-- this zone goes through.
bindTextSource :: TplStrSource s => Node -> s -> Tpl ()
bindTextSource = bindStrSource textProp

-- | What a template checkbox's state can bind to.
class TplBoolSource s where
  bindCheckedSource :: Node -> s -> Tpl ()

instance TplBoolSource Bool where
  bindCheckedSource (Node n) checked = emitT (W.txSetChecked n checked)

instance TplBoolSource (Signal Bool) where
  bindCheckedSource (Node n) (Signal s) = emitT (W.txBindChecked n s)

instance TplBoolSource (KField Bool) where
  bindCheckedSource n fd = bindCheckedField n 0 fd

-- | What a template date picker's value can bind to: a constant, a
-- signal, or the row's own Date field (docs/datetime-plan.md D10). The
-- 'KField' instance is 'KField Day' and not 'KField Int64', which is
-- what keeps a picker off the integer field it shares a tag with.
class TplDateSource s where
  bindDateSource :: Node -> s -> Tpl ()

instance TplDateSource Day where
  bindDateSource (Node n) day =
    let (y, m, d) = toGregorian day in emitT (W.txSetDate n (fromIntegral y) m d)

instance TplDateSource (Signal Day) where
  bindDateSource (Node n) (Signal s) = emitT (W.txBindDate n s)

instance TplDateSource (KField Day) where
  bindDateSource n fd = bindDateField n 0 fd

-- | The time picker's three sources.
class TplTimeSource s where
  bindTimeSource :: Node -> s -> Tpl ()

instance TplTimeSource TimeOfDay where
  bindTimeSource (Node n) t = emitT (W.txSetTime n (todHour t) (todMin t))

instance TplTimeSource (Signal TimeOfDay) where
  bindTimeSource (Node n) (Signal s) = emitT (W.txBindTime n s)

instance TplTimeSource (KField TimeOfDay) where
  bindTimeSource n fd = bindTimeField n 0 fd

-- | What a template image's source can bind to: constant bytes (the
-- registration runs at the transaction boundary, inside the template
-- scope's records), a Blob signal, or an element's Blob field.
class TplImageSource s where
  bindImageSource :: Node -> s -> Tpl ()

instance TplImageSource BS.ByteString where
  bindImageSource (Node n) bytes = emitTIO (W.txSetSource n <$> registerBlob bytes)

instance TplImageSource (Signal BS.ByteString) where
  bindImageSource (Node n) (Signal s) = emitT (W.txBindSource n s)

instance TplImageSource (KField BS.ByteString) where
  bindImageSource n fd = bindSourceField n 0 fd

-- | What a template F64 prop can bind to: a progress bar's fraction, a
-- slider's position, a choice's selected index. The 'KField' instance is
-- Double-ONLY, because Prop::Value is an F64 slot. A NUMERIC LITERAL
-- NEEDS ITS TYPE SAID OUT LOUD here and nowhere else — @progressBound
-- (0.5 :: Double)@ — since GHC defaults only when every class in the
-- constraint set is standard.
class TplNumberSource s where
  bindValueSource :: Node -> s -> Tpl ()

instance TplNumberSource Double where
  bindValueSource (Node n) x = emitT (W.txSetValue n x)

instance TplNumberSource (Signal Double) where
  bindValueSource (Node n) (Signal s) = emitT (W.txBindValue n s)

instance TplNumberSource (KField Double) where
  bindValueSource n fd = bindValueField n 0 fd

-- | Props on a TEMPLATE node — the live 'Attr' one zone down, attached by
-- 'withTplAttrs'. WHERE 'Attr' TAKES A VALUE, THIS TAKES A SOURCE, because
-- each stamped copy's prop can come from its own row.
data TplAttr where
  -- | This stamped element's flex weight within its row\/column. A
  -- CONSTANT and not a source: every copy of one blueprint divides its
  -- parent the same way.
  TplGrow :: Double -> TplAttr
  -- | Whether this stamped element spans its container's cross axis. A
  -- CONSTANT and not a source, for 'TplGrow''s reason.
  TplFill :: Bool -> TplAttr
  -- | A stamped container's cross-axis child placement (the live 'Align').
  TplAlign :: Align -> TplAttr
  -- | A stamped grid's auto columns at a floor, the blueprint twin of
  -- 'ColumnsAuto'. A CONSTANT, for 'TplGrow''s reason.
  TplColumnsAuto :: Double -> TplAttr
  -- | A stamped row that flows onto new lines, the blueprint twin of
  -- 'Wrap'. A CONSTANT, for 'TplGrow''s reason.
  TplWrap :: Bool -> TplAttr
  -- | This stamped CONTAINER's own padding, in layout units — the
  -- window inset two levels up and the live 'Inset' one zone down, the
  -- same number and the same prop.
  TplInset :: Double -> TplAttr
  -- | This stamped copy's accessibility IDENTIFIER — the authored key
  -- automation addresses it by, never spoken. THREE CONSTRUCTORS PER STR
  -- PROP, the live 'Attr''s pair plus the row's own field: a
  -- class-polymorphic one cannot infer a bare literal (docs/deferred.md,
  -- the Haskell text-surface entry).
  TplA11yId :: Text -> TplAttr
  TplA11yIdBound :: Signal Text -> TplAttr
  TplA11yIdField :: KField Text -> TplAttr
  -- | What an assistive client SPEAKS for this stamped copy. THE
  -- ROW-FIELD CASE IS WHY THIS PROP EXISTS: @TplA11yLabelField (field
  -- \@"title" \@Task)@ makes every row announce its own name.
  TplA11yLabel :: Text -> TplAttr
  TplA11yLabelBound :: Signal Text -> TplAttr
  TplA11yLabelField :: KField Text -> TplAttr
  -- | What ACTIVATING this stamped copy does — a verb phrase.
  -- ACTIVATION KINDS ONLY (button, checkbox, select, radio); the refusal
  -- is the ROOT'S, at declare time, naming the kind it refused.
  TplA11yHint :: Text -> TplAttr
  TplA11yHintBound :: Signal Text -> TplAttr
  TplA11yHintField :: KField Text -> TplAttr
  -- | This stamped copy's HELP TEXT. THE ROW-FIELD CASE IS WHY THIS PROP
  -- REACHES THE ZONE: @TplHelpField (field \@"note" \@Account)@ explains
  -- every copy in its own words.
  TplHelp :: Text -> TplAttr
  TplHelpBound :: Signal Text -> TplAttr
  TplHelpField :: KField Text -> TplAttr
  -- | The PROMPT this stamped field shows while its text is empty
  -- (docs\/search-plan.md S3). Entry, textarea and search only.
  TplPlaceholder :: Text -> TplAttr
  TplPlaceholderBound :: Signal Text -> TplAttr
  TplPlaceholderField :: KField Text -> TplAttr
  -- | The DESTINATION this stamped 'Link' label opens
  -- (docs\/tasks-s2-plan.md T3).
  TplHref :: Text -> TplAttr
  TplHrefBound :: Signal Text -> TplAttr
  TplHrefField :: KField Text -> TplAttr
  -- | What this stamped copy MEANS — semantic emphasis, never
  -- appearance. A CONSTANT; which role fits which kind is the ROOT'S
  -- call.
  TplRole :: Role -> TplAttr
  -- | Return in this stamped textarea sends (the live 'Submits'). A
  -- CONSTANT and not a source, for 'TplGrow''s reason: every copy of one
  -- blueprint has the same gesture.
  TplSubmits :: Bool -> TplAttr
  -- | A stamped slider's granularity (docs\/slider-plan.md S1): constant
  -- across the copies, like the range.
  TplStep :: Double -> TplAttr
  -- | A stamped slider's tick spacing (docs\/slider-plan.md S5), constant
  -- for 'TplStep''s reason.
  TplTickSpacing :: Double -> TplAttr
  -- | What this stamped copy takes from a paste — the closed kinds by
  -- name plus any custom format ids. A CONSTANT LIST AND NOT A SOURCE.
  -- Every backend gates the paste occurrence on the focused widget's
  -- accept list, so without this 'onPaste' at a Node could never fire
  -- (docs\/tpl-props-plan.md §1).
  TplAccepts :: [Text] -> TplAttr
  -- | What every stamped copy of this node hands over when dragged, and
  -- the operations it allows, carried with each copy's own identity —
  -- each representation a constant or the ROW'S OWN FIELD
  -- (docs\/dnd-plan.md §4). A copy's OWN payload, constants only, is
  -- 'setDragSourceAt' after its insert.
  TplDraggable :: TplClip -> [Op] -> TplAttr
  -- | Every stamped copy of this node receives drops, performing these
  -- operations; what it TAKES is its 'TplAccepts' list. The landing
  -- arrives at 'onDrop' on the Node, with the copy's keys.
  TplDropTarget :: [Op] -> TplAttr

applyTplAttr :: TplAttr -> Node -> Tpl ()
applyTplAttr (TplGrow weight) n = setGrow n weight
applyTplAttr (TplFill on) n = setFill n on
applyTplAttr (TplAlign a) n = setAlignWire n (alignWire a)
applyTplAttr (TplColumnsAuto minWidth) n = setColumnsAuto n minWidth
applyTplAttr (TplWrap on) n = setWrap n on
applyTplAttr (TplInset pad) n = setNodeInset n pad
applyTplAttr (TplA11yId v) n = bindStrSource a11yIdProp n v
applyTplAttr (TplA11yIdBound src) n = bindStrSource a11yIdProp n src
applyTplAttr (TplA11yIdField src) n = bindStrSource a11yIdProp n src
applyTplAttr (TplA11yLabel v) n = bindStrSource a11yLabelProp n v
applyTplAttr (TplA11yLabelBound src) n = bindStrSource a11yLabelProp n src
applyTplAttr (TplA11yLabelField src) n = bindStrSource a11yLabelProp n src
applyTplAttr (TplA11yHint v) n = bindStrSource a11yHintProp n v
applyTplAttr (TplA11yHintBound src) n = bindStrSource a11yHintProp n src
applyTplAttr (TplA11yHintField src) n = bindStrSource a11yHintProp n src
applyTplAttr (TplHelp v) n = bindStrSource helpProp n v
applyTplAttr (TplHelpBound src) n = bindStrSource helpProp n src
applyTplAttr (TplHelpField src) n = bindStrSource helpProp n src
applyTplAttr (TplPlaceholder v) n = bindStrSource placeholderProp n v
applyTplAttr (TplPlaceholderBound src) n = bindStrSource placeholderProp n src
applyTplAttr (TplPlaceholderField src) n = bindStrSource placeholderProp n src
applyTplAttr (TplHref v) n = bindStrSource hrefProp n v
applyTplAttr (TplHrefBound src) n = bindStrSource hrefProp n src
applyTplAttr (TplHrefField src) n = bindStrSource hrefProp n src
applyTplAttr (TplRole r) n = setNodeRole n r
applyTplAttr (TplSubmits on) n = setNodeSubmits n on
applyTplAttr (TplStep step) (Node n) = emitT (W.txSetStep n step)
applyTplAttr (TplTickSpacing spacing) (Node n) = emitT (W.txSetTickSpacing n spacing)
applyTplAttr (TplAccepts kinds) n = setNodeAccepts n kinds
applyTplAttr (TplDraggable clip ops) n = setNodeDragSource n clip ops
applyTplAttr (TplDropTarget ops) n = setNodeDropTarget n ops

setNodeAccepts :: Node -> [Text] -> Tpl ()
setNodeAccepts (Node n) kinds = emitT (W.txSetAccepts n (T.unpack (acceptList kinds)))

-- | The dynamic path under 'TplDraggable'; a withdraw needs it.
setNodeDragSource :: Node -> TplClip -> [Op] -> Tpl ()
setNodeDragSource (Node n) clip ops = emitTIO (tplDragSourceRecord n clip ops)

-- | The dynamic path under 'TplDropTarget'.
setNodeDropTarget :: Node -> [Op] -> Tpl ()
setNodeDropTarget (Node n) ops =
  emitT (W.txSetDropTarget n (operationMask ops) 0 [])

setNodeInset :: Node -> Double -> Tpl ()
setNodeInset (Node n) pad = emitT (W.txSetInset n pad)

-- | A stamped copy carries attribute runs (the live 'setRich').
setNodeRich :: Node -> Bool -> Tpl ()
setNodeRich (Node n) on = emitT (W.txSetRich n on)

-- | A stamped textarea sends on Return (the live 'setSubmits').
setNodeSubmits :: Node -> Bool -> Tpl ()
setNodeSubmits (Node n) on = emitT (W.txSetSubmits n on)

setNodeRole :: Node -> Role -> Tpl ()
setNodeRole (Node n) r = emitT (W.txSetRole n (roleWire r))

-- | Props on a template node. A COMBINATOR AND NOT AN EXTRA ARITY: a
-- second 'BothZones' instance at the @[a] -> r@ head is GHC-59692
-- "Duplicate instance declarations", and every constructor's
-- @-> Tpl Node@ signature is what tools\/tpl-surfaces.py reads.
withTplAttrs :: [TplAttr] -> Tpl Node -> Tpl Node
withTplAttrs attrs act = do
  n <- act
  mapM_ (`applyTplAttr` n) attrs
  return n

label :: TplStrSource s => s -> Tpl Node
label src = do
  n <- widget W.kindLabel
  bindTextSource n src
  return n

-- | A stamped label wearing 'Heading', in one word: the row's own
-- section title, styled and announced as a heading.
heading :: TplStrSource s => s -> Tpl Node
heading src = do
  n <- label src
  setNodeRole n Heading
  return n

-- | Its counterpart, stamped: the footnote under the content it
-- explains.
caption :: TplStrSource s => s -> Tpl Node
caption src = do
  n <- label src
  setNodeRole n Caption
  return n

checkbox :: TplBoolSource s => s -> ([Key] -> Bool -> IO ()) -> Tpl Node
checkbox src handler = do
  n@(Node i) <- widget W.kindCheckbox
  bindCheckedSource n src
  pendT (PToggleNode i handler)
  return n

-- | A template image; decode failure renders the placeholder, never a
-- crash, on every backend.
-- | A stamped date picker over an addressable source, with its pick
-- handler co-located; the handler receives the copy's keys first.
datePicker :: TplDateSource s => s -> ([Key] -> Day -> IO ()) -> Tpl Node
datePicker src handler = do
  n@(Node i) <- widget W.kindDatePicker
  bindDateSource n src
  pendT (PDateNode i handler)
  return n

-- | A stamped time picker; the date picker's contract, hours and minutes.
timePicker :: TplTimeSource s => s -> ([Key] -> TimeOfDay -> IO ()) -> Tpl Node
timePicker src handler = do
  n@(Node i) <- widget W.kindTimePicker
  bindTimeSource n src
  pendT (PTimeNode i handler)
  return n

image :: TplImageSource s => s -> Tpl Node
image src = do
  n <- widget W.kindImage
  bindImageSource n src
  return n

-- | A stamped button whose caption comes from an addressable source — a
-- signal, or the ROW'S OWN field, which is the thing @button "text"@ cannot
-- say and the thing a list of named actions wants ("Delete <title>").
buttonBound :: TplStrSource s => s -> Tpl Node
buttonBound src = do
  n <- widget W.kindButton
  bindTextSource n src
  return n

-- | A stamped entry SEEDED from an addressable source: the copy opens
-- holding the row's own text. STILL UNCONTROLLED — the field owns its
-- text from the first keystroke and the source keeps writing, so seed
-- from a field the app does NOT write back to, or the caret moves while
-- the user types.
entryBound :: TplStrSource s => s -> Tpl Node
entryBound src = do
  n <- widget W.kindEntry
  bindTextSource n src
  return n

-- | A stamped textarea seeded from an addressable source;
-- 'entryBound''s contract over the multi-line control.
textareaBound :: TplStrSource s => s -> Tpl Node
textareaBound src = do
  n <- widget W.kindTextarea
  bindTextSource n src
  return n

-- | A stamped RICH textarea whose whole document is the row's own
-- 'Document' field (docs\/rich-text-plan.md §19): @rich@ FIRST and then
-- the bound document — the core refuses the one without the other before
-- it — and the bind is recorded so a copy's own act folds into its ROW.
-- CONTROLLED where 'textareaBound' is not: the app writes a copy's
-- document by patching the row, and the copy's own acts come back folded.
textareaRichBound :: KField Document -> Tpl Node
textareaRichBound fd@(KField i) = do
  n@(Node ident) <- widget W.kindTextarea
  setNodeRich n True
  held <- openFor 0
  mapM_ (\cid -> pendT (PDocumentBind ident cid i 0)) held
  bindDocumentField n 0 fd
  return n

-- The For this template body is being declared inside, @level@ Fors up.
openFor :: Word32 -> Tpl (Maybe Word64)
openFor level = gets $ \s -> listToMaybe (drop (fromIntegral level) (s.bOpenFors))

-- | A stamped search field seeded from an addressable source;
-- 'entryBound''s contract under the platform's search chrome.
searchBound :: TplStrSource s => s -> Tpl Node
searchBound src = do
  n <- widget W.kindSearch
  bindTextSource n src
  return n

-- | A template row: the live 'row' one zone down, taking NODES.
rowOf :: [Tpl Node] -> Tpl Node
rowOf = containerOf W.kindRow

-- | A template column.
columnOf :: [Tpl Node] -> Tpl Node
columnOf = containerOf W.kindColumn

-- | A template scroll viewport over EXACTLY ONE child — the signature says
-- so, as the live 'scroll''s does.
scrollOf :: Tpl Node -> Tpl Node
scrollOf child = containerOf W.kindScroll [child]

-- | A template grid, laying each stamped copy's children row-major into
-- @columns@ columns. The count describes the PROTOTYPE and stays a
-- constant.
gridOf :: Int -> [Tpl Node] -> Tpl Node
gridOf = gridWith

-- | A LABELLED ROW per stamped copy — the live 'labeled' one zone down,
-- taking Nodes: the source names the one control the children declare,
-- with an optional trailing button after it.
labeledOf :: TplStrSource s => s -> [Tpl Node] -> Tpl Node
labeledOf src children = containerOf W.kindLabeled (label src : children)

-- | A canvas per stamped copy — a sparkline in a table cell, the case
-- set_drawing grew its keys-first addressing for (docs/canvas-plan.md
-- §3.1). The drawing is declared with the node, so every copy is born
-- with it; 'drawAt' re-declares one copy's afterwards.
--
-- NO SIZE POLICY HERE, and the type is the refusal: a stamped copy keeps
-- @scale@ (docs/deferred.md, the size-policy entry).
canvasOf :: Viewbox -> [DrawOp] -> Tpl Node
canvasOf vb ops = do
  n@(Node i) <- widget W.kindCanvas
  emitT (drawingRecord i [] vb ops)
  return n

-- | A stamped progress bar whose fraction follows an addressable source — the
-- per-row case this zone exists for, @progressBound (field \@"done" \@Task)@.
progressBound :: TplNumberSource s => s -> Tpl Node
progressBound src = do
  n <- widget W.kindProgress
  bindValueSource n src
  return n

-- | A stamped slider over @lo@..@hi@ whose POSITION comes from a source.
slider :: TplNumberSource s => Double -> Double -> s -> Tpl Node
slider lo hi src = do
  n@(Node i) <- widget W.kindSlider
  emitT (W.txSetMin i lo)
  emitT (W.txSetMax i hi)
  bindValueSource n src
  return n

-- | A stamped dropdown over fixed options — each option becomes a label child
-- — with the SELECTED 0-based index from a source.
select :: TplNumberSource s => [Text] -> s -> Tpl Node
select = choiceWith W.kindSelect

-- | A stamped radio group: 'select''s contract in its inline
-- presentation — same option children, same index, same registrar.
radio :: TplNumberSource s => [Text] -> s -> Tpl Node
radio = choiceWith W.kindRadio

-- The options are built CHILDREN-FIRST — declare the label, set its
-- text, then addChild. gtk.rs reads an option's text AT the AddChild, so
-- a text set afterwards arrives too late (docs/traps.md, "prop writes
-- before AddChild").
choiceWith :: TplNumberSource s => Word32 -> [Text] -> s -> Tpl Node
choiceWith kind options src = do
  n <- widget kind
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setTextProp o optionText
        addChild n o
    )
    options
  bindValueSource n src
  return n

-- | Re-declare ONE stamped copy's drawing: the canvas template Node plus
-- that copy's keys, outermost first. An empty key list re-declares the
-- drawing every copy is born with, which is what 'canvasOf' spells at
-- declaration time (docs/canvas-plan.md §3.1).
drawAt :: Node -> [Key] -> Viewbox -> [DrawOp] -> Build ()
drawAt (Node n) keys vb ops = emitB (drawingRecord n (map keyValue keys) vb ops)

-- | Re-declare ONE stamped copy's header bar: the table's template Node
-- plus that copy's keys, outermost first. An empty key list re-declares
-- the bar for every copy. The core walls the template bar being declared
-- first.
columnsAt :: Node -> [Key] -> [Text] -> Sort -> Build ()
columnsAt (Node n) keys0 titles sort =
  let keys = map keyValue keys0 in
  emitB
    ( W.txSetColumnHeaders
        n
        (sort.sortColumn)
        (sort.sortDirection)
        (fromIntegral (length titles))
        (fromIntegral (length keys))
        -- Keys FIRST, then the titles (the record's own convention).
        (keys ++ map (W.VStr . T.unpack) titles)
    )

-- Sums: the data declaration is the sum. (tools/check-sugar-surface.py
-- scans columnsAt up to THIS line, so the sentence is load-bearing.)

bindTextElement :: Node -> Word32 -> Tpl ()
bindTextElement (Node n) level = emitT (W.txBindTextElement n level 0)


-- | Bind a label's text to one field of the element; KField Text
-- only — the phantom pins it at compile time.
bindTextField :: Node -> Word32 -> KField Text -> Tpl ()
bindTextField (Node n) level (KField i) = emitT (W.txBindTextElement n level i)

-- | Bind a date picker's value to one field of the element; KField Day
-- only (docs/datetime-plan.md D10).
bindDateField :: Node -> Word32 -> KField Day -> Tpl ()
bindDateField (Node n) level (KField i) = emitT (W.txBindDateElement n level i)

-- | Bind a time picker's value to one field of the element.
bindTimeField :: Node -> Word32 -> KField TimeOfDay -> Tpl ()
bindTimeField (Node n) level (KField i) = emitT (W.txBindTimeElement n level i)

-- | Bind a checkbox's state to one field of the element; KField Bool
-- only.
bindCheckedField :: Node -> Word32 -> KField Bool -> Tpl ()
bindCheckedField (Node n) level (KField i) = emitT (W.txBindCheckedElement n level i)

-- | Bind an F64 prop — a progress fraction, a slider position, a
-- choice's index — to one field of the element; KField Double only,
-- because the slot is F64 and an I64 field would be a scene error at
-- declaration rather than a compile error here.
bindValueField :: Node -> Word32 -> KField Double -> Tpl ()
bindValueField (Node n) level (KField i) = emitT (W.txBindValueElement n level i)

-- | Bind an image's source to one Blob field of the element; KField
-- ByteString only.
bindSourceField :: Node -> Word32 -> KField BS.ByteString -> Tpl ()
bindSourceField (Node n) level (KField i) = emitT (W.txBindSourceElement n level i)

-- | Bind a stamped rich textarea's whole document to one field of the
-- element; @KField Document@ only (docs\/rich-text-plan.md §19).
bindDocumentField :: Node -> Word32 -> KField Document -> Tpl ()
bindDocumentField (Node n) level (KField i) = emitT (W.txBindDocumentElement n level i)

-- | The app thread, learned when the dispatch loop starts. Nothing
-- before then, which is the single-threaded construction phase.
appThreadRef :: IORef (Maybe ThreadId)
appThreadRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE appThreadRef #-}

-- | The Haskell spelling of a rule the handle bindings get from a
-- stale-transaction check.
requireAppThread :: IO ()
requireAppThread = do
  owner <- readIORef appThreadRef
  case owner of
    Just expected -> do
      here <- myThreadId
      if here /= expected
        then
          error
            ( "kaya: a transaction belongs to the app thread -- this is thread "
                ++ show here
                ++ ", the app thread is "
                ++ show expected
                ++ ". To mutate from a background thread use post, which runs your "
                ++ "action as a transaction over there."
            )
        else return ()
    Nothing -> return ()

-- | 'buildTx' up to the transaction's bytes, submitting nothing.
-- Exported for guests/haskell's AbortCheck, which reads a ranged format
-- act's record back (docs\/rich-text-plan.md §17) — 'buildTx' is this
-- plus the submit, so the check reads the path an app takes.
stageTx :: App -> Build a -> IO (a, Builder)
stageTx app (Build f) = do
  requireAppThread
  counters <- readIORef (app.appCounters)
  (model, children) <- readIORef (app.appModel)
  fresh <- readIORef (app.appFresh)
  derived <- readIORef (app.appDerived)
  let (a, s) = runState f (BuildState counters mempty model fresh children [] [] derived)
  -- Force the Build's final state before the first store-back: a Build
  -- that throws must throw HERE, where the boundary abandons everything
  -- — never later, from a poisoned thunk inside an IORef.
  _ <- evaluate s
  -- Serialize now, before any store-back: this runs the records' IO, which is
  -- where image sources and Blob record fields register their bytes with the
  -- core — in record order, immediately before the submit whose handle table
  -- they fill.
  records <- s.bRecords
  writeIORef (app.appCounters) (s.bCounters)
  writeIORef (app.appModel) (s.bModel, s.bChildren)
  writeIORef (app.appFresh) (s.bFresh)
  writeIORef (app.appDerived) (s.bDerived)
  -- Handlers declared at their constructors register alongside the
  -- submit; a Build that threw never reaches here, abandoning them
  -- with its records.
  mapM_ (register app) (reverse (s.bPending))
  return (a, records)

-- | Run a Build to records, submit them as one transaction, and return
-- the block's result. The model folds inside the Build's pure state and
-- is stored back in 'stageTx' alongside the submit — a transaction that
-- never reaches this point (its Build threw) leaves the model as
-- committed.
buildTx :: App -> Build a -> IO a
buildTx app b = do
  (a, records) <- stageTx app b
  -- The pending link-route declarations go FIRST, in declaration order
  -- (docs/app-links-plan.md §4; Rust's PENDING_ROUTES drained head-first
  -- by Tx::commit is the shape).
  routes <- readIORef (app.appPendingRoutes)
  writeIORef (app.appPendingRoutes) []
  kayaSubmit (routes ++ [records])
  return a

register :: App -> Pending -> IO ()
register app pending = case pending of
  PClick n handler -> modifyIORef' (app.appWidgetHandlers) (Map.insert n handler)
  PAlert n handler -> modifyIORef' (app.appAlertHandlers) (Map.insert n handler)
  PNotification n handler ->
    modifyIORef' (app.appNotificationHandlers) (Map.insert n handler)
  PFileDialog n handler ->
    modifyIORef' (app.appFileDialogHandlers) (Map.insert n handler)
  PClipboardRead n handler ->
    modifyIORef' (app.appClipboardReads) (Map.insert n handler)
  PEntryPopped n handler -> modifyIORef' (app.appEntryPopped) (Map.insert n handler)
  PSectionSelected n handler -> modifyIORef' (app.appSectionSelected) (Map.insert n handler)
  PBackRequested n handler -> modifyIORef' (app.appBackRequested) (Map.insert n handler)
  PSheetDismissed n handler -> modifyIORef' (app.appSheetDismissed) (Map.insert n handler)
  PDismissRequested n handler -> modifyIORef' (app.appDismissRequested) (Map.insert n handler)
  PCloseRequested n handler -> modifyIORef' (app.appCloseRequested) (Map.insert n handler)
  PWindowClosed n handler -> modifyIORef' (app.appWindowClosed) (Map.insert n handler)
  -- The undo pair keys the same per-WINDOW tables the dispatch loop
  -- reads; n is the window construct's id.
  PUndone n handler -> modifyIORef' (app.appUndone) (Map.insert n handler)
  PRedone n handler -> modifyIORef' (app.appRedone) (Map.insert n handler)
  PChange n handler -> modifyIORef' (app.appWidgetChanges) (Map.insert n handler)
  PToggle n handler -> modifyIORef' (app.appWidgetToggles) (Map.insert n handler)
  PValue n handler -> modifyIORef' (app.appWidgetValues) (Map.insert n handler)
  PToggleNode n handler -> modifyIORef' (app.appNodeToggles) (Map.insert n handler)
  PDocumentBind n cid i level ->
    modifyIORef' (app.appDocumentBinds) (Map.insert n (cid, i, level))
  PEditNode n handler -> modifyIORef' (app.appNodeEdits) (Map.insert n handler)
  PFormatNode n handler -> modifyIORef' (app.appNodeFormats) (Map.insert n handler)
  PDate n handler -> modifyIORef' (app.appWidgetDates) (Map.insert n handler)
  PTime n handler -> modifyIORef' (app.appWidgetTimes) (Map.insert n handler)
  PDateNode n handler -> modifyIORef' (app.appNodeDates) (Map.insert n handler)
  PTimeNode n handler -> modifyIORef' (app.appNodeTimes) (Map.insert n handler)
  PMenuActivated n handler -> modifyIORef' (app.appMenuActivated) (Map.insert n handler)
  PMenuActivatedNode n handler -> modifyIORef' (app.appMenuActivatedNode) (Map.insert n handler)
  PMenuToggled n handler -> modifyIORef' (app.appMenuToggled) (Map.insert n handler)
  PMenuToggledNode n handler -> modifyIORef' (app.appMenuToggledNode) (Map.insert n handler)
  PMenuSelected n handler -> modifyIORef' (app.appMenuSelected) (Map.insert n handler)
  PMenuSelectedNode n handler -> modifyIORef' (app.appMenuSelectedNode) (Map.insert n handler)

-- | buildTx for handlers that keep no handles.
submitTx :: App -> Build () -> IO ()
submitTx app b = buildTx app b

-- | 'buildTx' as ONE undoable step, named @label@ (docs/undo-plan.md
-- D2). The marker is emitted before @body@ runs, so no call order can
-- put it anywhere but first. WHAT A GROUP MAY HOLD is the reactive half
-- — signal writes and collection deltas; anything else fails at apply,
-- naming the op. The label must be NON-EMPTY: the empty one is how a
-- typing episode names itself.
undoableTx :: App -> Text -> Build a -> IO a
undoableTx app = undoableTxIn app 0

-- | 'undoableTx' against an auxiliary window's ledger; each window has
-- its own history.
undoableTxIn :: App -> Word64 -> Text -> Build a -> IO a
undoableTxIn app windowId label body =
  buildTx app (emitB (W.txUndoGroup windowId (W.VStr (T.unpack label))) >> body)

-- Fold an undo's payload into the collection model; the payload is
-- core-authoritative.
--
-- NO DERIVED RECOMPUTE HERE, DELIBERATELY: a derived signal's write rode
-- the SAME transaction as the mutation that caused it, so the core has
-- already restored it by the time this runs.
absorbUndo :: App -> UndoDelta -> IO ()
absorbUndo app delta = modifyIORef' (app.appModel) fold
  where
    fold (model, children) = (foldl order (foldl entry model (undoEntries delta)) (undoOrders delta), children)
    -- The payload is 'Key's; the model is keyed by the wire's own value.
    entry model e = case ueState e of
      Just (variant, record) ->
        modelSet (ueCollection e) (path e) (keyValue (ueKey e)) variant record model
      -- The entry is gone in the restored state. Its own instance
      -- only: the payload states what each entry IS, and an instance
      -- it never names is one this undo did not touch.
      Nothing -> Map.adjust (map (drop1 (path e) (keyValue (ueKey e)))) (ueCollection e) model
    path = map keyValue . uePath
    drop1 p key i
      | i.iPath == p = i {iEntries = filter ((/= key) . fst) (i.iEntries)}
      | otherwise = i
    order model o = Map.adjust (map (place o)) (uoCollection o) model
    place o i
      | i.iPath == map keyValue (uoPath o) =
          -- Positioned by the payload's list, keeping anything it does
          -- not name at the end: an entry the delta never mentions is
          -- one this undo did not move.
          let wanted = map keyValue (uoKeys o)
              named = [(k, v) | k <- wanted, Just v <- [lookup k (i.iEntries)]]
              rest = filter ((`notElem` wanted) . fst) (i.iEntries)
           in i {iEntries = named ++ rest}
      | otherwise = i

-- | The registration vocabulary, shared by both zones: a handler is
-- registered at the element that produced the occurrence. ONE CLASS, NOT
-- ONE PER VERB — -Werror=missing-methods fires only for a method missing
-- from an EXISTING instance, so six one-method classes would turn a
-- skipped zone into a MISSING INSTANCE, an error only where a guest
-- calls it (docs/deferred.md, the nested RECORD collection entry).
class HandlerTarget e where
  -- | What this zone hands a handler ahead of the payload @p@: nothing in
  -- the live zone, the stamped copy's key path (outermost first) in a
  -- template. ONE STATEMENT OF THAT RULE for every verb — a handler type
  -- written out per verb can promise the template arm the LIVE shape and
  -- still compile.
  type Keyed e p

  onClick :: App -> e -> Keyed e (IO ()) -> IO ()

  -- | The field owns its text and reports each edit here; the app folds
  -- the text into its own state — there is no read-back, by doctrine.
  onChange :: App -> e -> Keyed e (Text -> IO ()) -> IO ()

  -- | The field's text at the moment of the platform's submit gesture
  -- (docs\/submit-plan.md S7).
  onSubmit :: App -> e -> Keyed e (Text -> IO ()) -> IO ()

  -- | The box owns its checked bit and reports each flip here; the app
  -- folds it into its own state.
  onToggle :: App -> e -> Keyed e (Bool -> IO ()) -> IO ()

  -- | A slider, select or radio reports each move with the new value —
  -- the entry's uncontrolled contract, with a Double.
  onValueChanged :: App -> e -> Keyed e (Double -> IO ()) -> IO ()

  -- | The value a slider gesture SETTLED ON — once per release or key
  -- move, after that gesture's 'onValueChanged' moves
  -- (docs\/slider-plan.md S2).
  onValueCommitted :: App -> e -> Keyed e (Double -> IO ()) -> IO ()

  -- | Take pasted content. COSTS NOTHING ON ANY PLATFORM, unlike
  -- 'readClipboard': a paste is a user gesture, so it is its own
  -- authorisation.
  onPaste :: App -> e -> Keyed e (Representation -> IO ()) -> IO ()

  -- | The table's header-click handler, registered at its For; the
  -- payload is the 0-based column of a sort REQUEST. Nothing has changed
  -- on screen: reorder the collection by key and re-declare the header —
  -- 'columns' live, 'columnsAt' per stamped copy (docs\/tables-plan.md).
  onSort :: App -> e -> Keyed e (Int -> IO ()) -> IO ()

  -- | Take dropped content here (docs\/dnd-plan.md D8): a live widget's
  -- own drops or a reorderable For's landings, and at a Node the drops on
  -- every stamped copy, the copy's keys first. Only fires for a widget
  -- that declared 'DropTarget' over an accept list.
  onDrop :: App -> e -> Keyed e (Dropped -> IO ()) -> IO ()

  -- | A drag that began here has ended: 'Nothing' is a cancelled or
  -- refused drag, not an error. At a Node — a reorderable row is one —
  -- the copy's keys come first.
  onDragEnded :: App -> e -> Keyed e (Maybe Op -> IO ()) -> IO ()

instance HandlerTarget Widget where
  type Keyed Widget p = p
  onClick app (Widget n) handler =
    modifyIORef' (app.appWidgetHandlers) (Map.insert n handler)
  onChange app (Widget n) handler =
    modifyIORef' (app.appWidgetChanges) (Map.insert n handler)
  onSubmit app (Widget n) handler =
    modifyIORef' (app.appWidgetSubmits) (Map.insert n handler)
  onToggle app (Widget n) handler =
    modifyIORef' (app.appWidgetToggles) (Map.insert n handler)
  onValueChanged app (Widget n) handler =
    modifyIORef' (app.appWidgetValues) (Map.insert n handler)
  onValueCommitted app (Widget n) handler =
    modifyIORef' (app.appWidgetCommits) (Map.insert n handler)
  onPaste app (Widget n) handler =
    modifyIORef' (app.appWidgetPastes) (Map.insert n handler)
  onSort app (Widget n) handler =
    modifyIORef' (app.appSortHandlers) (Map.insert n handler)
  onDrop app (Widget n) handler =
    modifyIORef' (app.appWidgetDrops) (Map.insert n handler)
  onDragEnded app (Widget n) handler =
    modifyIORef' (app.appDragEnded) (Map.insert n handler)

instance HandlerTarget Node where
  type Keyed Node p = [Key] -> p
  onClick app (Node n) handler =
    modifyIORef' (app.appNodeHandlers) (Map.insert n handler)
  onChange app (Node n) handler =
    modifyIORef' (app.appNodeChanges) (Map.insert n handler)
  onSubmit app (Node n) handler =
    modifyIORef' (app.appNodeSubmits) (Map.insert n handler)
  onToggle app (Node n) handler =
    modifyIORef' (app.appNodeToggles) (Map.insert n handler)
  onValueChanged app (Node n) handler =
    modifyIORef' (app.appNodeValues) (Map.insert n handler)
  onValueCommitted app (Node n) handler =
    modifyIORef' (app.appNodeCommits) (Map.insert n handler)
  onPaste app (Node n) handler =
    modifyIORef' (app.appNodePastes) (Map.insert n handler)
  onSort app (Node n) handler =
    modifyIORef' (app.appNodeSorts) (Map.insert n handler)
  onDrop app (Node n) handler =
    modifyIORef' (app.appNodeDrops) (Map.insert n handler)
  onDragEnded app (Node n) handler =
    modifyIORef' (app.appNodeDragEnded) (Map.insert n handler)

-- | Turn the decoder's kind-and-parts into the sum, or Nothing. EMPTY
-- IS THE UNIVERSAL NO: Nothing covers a denied prompt, an unfocused
-- reader, an empty clipboard and content in no accepted representation
-- alike, because the platforms deliberately do not say which.
representationOf :: Maybe W.ClipValues -> Maybe Representation
representationOf Nothing = Nothing
representationOf (Just cv)
  | kind == W.clipText = Just (RText (str 0))
  | kind == W.clipHtml = Just (RHtml (str 0))
  | kind == W.clipImage = Just (RImage (bytes 0))
  | kind == W.clipCustom = Just (RCustom (strRaw 0) (bytes 1))
  -- The picker's own three-per-file grouping, so a guest that decodes a
  -- dialog result decodes this with the same loop.
  | kind == W.clipFiles = Just (RFiles (regroup (W.clipValues cv)))
  | otherwise = Nothing
  where
    kind = W.clipKind cv
    part i = case drop i (W.clipValues cv) of p : _ -> Just p; [] -> Nothing
    str i = case part i of Just (W.CStr t) -> T.pack t; _ -> ""
    strRaw i = case part i of Just (W.CStr t) -> T.pack t; _ -> ""
    bytes i = case part i of Just (W.CBytes b) -> b; _ -> BS.empty
    regroup (W.CI64 h : W.CStr n : W.CStr p : rest) =
      PickedFile (fromIntegral h) (T.pack n) p : regroup rest
    regroup _ = []

-- | A fresh app: zeroed id counters, an empty model, empty dispatch
-- tables. kayaMain starts from one; headless checks use it directly.
--
-- EVERY LINE BELOW NAMES ITS FIELD, because this chain is POSITIONAL and
-- most fields are @IORef (Map …)@ filled with the same polymorphic
-- @Map.empty@: a new table inserted one line off would typecheck and
-- silently swap two dispatch tables.
newApp :: IO App
newApp =
  App
    <$> newMVar [] -- appPosted
    <*> newIORef (Counters 0 0 0 0 0 0 0) -- appCounters
    <*> newIORef (Map.empty, Map.empty) -- appModel
    <*> newIORef Map.empty -- appFresh
    <*> newIORef Map.empty -- appDerived
    <*> newIORef Map.empty -- appWidgetHandlers
    <*> newIORef Map.empty -- appSortHandlers
    <*> newIORef Map.empty -- appNodeSorts
    <*> newIORef Map.empty -- appNodeHandlers
    <*> newIORef Map.empty -- appWidgetChanges
    <*> newIORef Map.empty -- appNodeChanges
    <*> newIORef Map.empty -- appWidgetSubmits
    <*> newIORef Map.empty -- appNodeSubmits
    <*> newIORef Map.empty -- appDocuments
    <*> newIORef Map.empty -- appDocumentBinds
    <*> newIORef Map.empty -- appNodeEdits
    <*> newIORef Map.empty -- appNodeFormats
    <*> newIORef Map.empty -- appWidgetEdits
    <*> newIORef Map.empty -- appWidgetFormats
    <*> newIORef Map.empty -- appWidgetToggles
    <*> newIORef Map.empty -- appNodeToggles
    <*> newIORef Map.empty -- appWidgetValues
    <*> newIORef Map.empty -- appNodeValues
    <*> newIORef Map.empty -- appWidgetCommits
    <*> newIORef Map.empty -- appNodeCommits
    <*> newIORef Map.empty -- appWidgetDates
    <*> newIORef Map.empty -- appNodeDates
    <*> newIORef Map.empty -- appWidgetTimes
    <*> newIORef Map.empty -- appNodeTimes
    <*> newIORef Map.empty -- appCloseRequested
    <*> newIORef Map.empty -- appWindowClosed
    <*> newIORef Map.empty -- appEntryPopped
    <*> newIORef Map.empty -- appSectionSelected
    <*> newIORef Map.empty -- appBackRequested
    <*> newIORef Map.empty -- appSheetDismissed
    <*> newIORef Map.empty -- appDismissRequested
    <*> newIORef Map.empty -- appAlertHandlers
    <*> newIORef Map.empty -- appNotificationHandlers
    <*> newIORef Nothing -- appNotificationActivation
    <*> newIORef Map.empty -- appLinkHandlers
    <*> newIORef 0 -- appNextLinkRoute
    <*> newIORef [] -- appPendingRoutes
    <*> newIORef Map.empty -- appUndone
    <*> newIORef Map.empty -- appRedone
    <*> newIORef Map.empty -- appFileDialogHandlers
    <*> newIORef Map.empty -- appClipboardReads
    <*> newIORef Map.empty -- appWidgetPastes
    <*> newIORef Map.empty -- appNodePastes
    <*> newIORef Map.empty -- appWidgetDrops
    <*> newIORef Map.empty -- appNodeDrops
    <*> newIORef Map.empty -- appDragEnded
    <*> newIORef Map.empty -- appNodeDragEnded
    <*> newIORef Map.empty -- appMenuActivated
    <*> newIORef Map.empty -- appMenuActivatedNode
    <*> newIORef Map.empty -- appMenuToggled
    <*> newIORef Map.empty -- appMenuToggledNode
    <*> newIORef Map.empty -- appMenuSelected
    <*> newIORef Map.empty -- appMenuSelectedNode
    <*> newIORef Map.empty -- appDraws

-- | Set up (build the scene, register handlers) and run: occurrences
-- dispatch on the app thread while the core owns the calling thread,
-- which must be the process main thread (GHC's main runs bound to it;
-- -threaded is required).
kayaMain :: (App -> IO ()) -> IO ()
kayaMain setup = do
  app <- newApp
  setup app
  done <- newEmptyMVar
  _ <- forkIO (dispatchLoop app >> putMVar done ())
  code <- kayaRun
  takeMVar done
  if code == 0 then exitSuccess else exitWith (ExitFailure (fromIntegral code))

-- The ring hands a key path as wire values; a handler receives 'Key's.
keyPath :: [W.Value] -> [Key]
keyPath = map keyOfWire

-- | One handler dispatch: an exception crosses the build boundary (the
-- pure Build's store-back and submit never ran, so the model shows
-- exactly what was shipped), is logged, and the loop moves on.
dispatch :: IO () -> IO ()
dispatch body =
  body `catch` \e ->
    hPutStrLn stderr ("kaya: handler threw (transaction rolled back): " ++ show (e :: SomeException))

-- | Run @body@ as a transaction on the app thread, soon. THE ONE action
-- safe to call from another thread. A posted action runs in its OWN
-- transaction, after whatever is running now, so posting from inside a
-- handler queues for after and never nests.
post :: App -> IO () -> IO ()
post app body = do
  modifyMVar_ (app.appPosted) (return . (++ [body]))
  -- The app thread may be parked in C waiting on the ring. Posted work
  -- is not an occurrence and never enters that ring, so this is the
  -- only way it hears about it.
  wake

-- | Run everything posted, each as its own transaction, in order. The
-- batch is taken and the MVar put back BEFORE any of it runs, so an
-- action that posts again lands in the NEXT batch; holding the MVar
-- across the calls would deadlock the moment one of them posted.
drainPosted :: App -> IO ()
drainPosted app = do
  batch <- modifyMVar (app.appPosted) (\queued -> return ([], queued))
  mapM_ dispatch batch

dispatchLoop :: App -> IO ()
dispatchLoop app = do
  -- Claim the thread before the first occurrence: every build after
  -- this point must happen here.
  myThreadId >>= \here -> writeIORef appThreadRef (Just here)
  -- Posted work first, then the ring, then park. Draining at the TOP is
  -- what makes a wake sufficient: whatever brought this thread back, it
  -- looks here before anywhere else.
  drainPosted app
  occurrence <- pollOccurrence
  case occurrence of
    Nothing -> do
      more <- waitOccurrences
      if more then dispatchLoop app else return () -- shutdown
    Just (kind, ident, keys, payload, clip, drop_, undone, askTail)
      -- THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER MAPPED
      -- (docs/canvas-plan.md §3.2.1): this calls the registered function
      -- for the size the core asked about and submits the one
      -- set_drawing itself, in a transaction the BINDING opens
      -- (tools/check-ambient-tx.py). The size the ask carried IS the new
      -- viewbox.
      | kind == W.occKindDrawRequested || kind == W.occKindTick -> do
          draws <- readIORef (app.appDraws)
          case Map.lookup ident draws of
            Nothing -> return ()
            Just f ->
              dispatch $ do
                let (box, time) = askSize askTail
                submitTx app (emitB (drawingRecord ident [] box (f box time)))
          dispatchLoop app
      | kind == W.occKindSortRequested -> do
          let column = case payload of Just (W.VI64 n) -> fromIntegral n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appSortHandlers)
              dispatch (mapM_ ($ column) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeSorts)
              dispatch (mapM_ (\h -> h (keyPath keys) column) (Map.lookup ident handlers))
          dispatchLoop app
      -- THE MIRROR IS FOLDED BEFORE THE HANDLER RUNS, so a handler
      -- reading 'document' sees the edit it was told about
      -- (docs/rich-text-plan.md R1). The tail is source, start, stop, the
      -- inserted text, then four values per run.
      | kind == W.occKindTextEdited -> do
          case askTail of
            (W.VI64 source : W.VI64 start : W.VI64 stop : W.VStr inserted : values) -> do
              let e =
                    Edit
                      (fromIntegral start, fromIntegral stop)
                      (T.pack inserted)
                      (runsOfValues values)
                      (Just (editSourceOfWire (fromIntegral source)))
              -- A STAMPED COPY FOLDS INTO ITS ROW and a live widget
              -- into the mirror, one fold either way
              -- (docs/rich-text-plan.md §19).
              case keys of
                [] -> do
                  absorbEdit app (Widget ident) e
                  handlers <- readIORef (app.appWidgetEdits)
                  dispatch (mapM_ ($ e) (Map.lookup ident handlers))
                _ -> do
                  foldRowDocument app (Node ident) (keyPath keys) (foldEdit e)
                  handlers <- readIORef (app.appNodeEdits)
                  dispatch (mapM_ (\h -> h (keyPath keys) e) (Map.lookup ident handlers))
            _ -> return ()
          dispatchLoop app
      | kind == W.occKindTextFormatted -> do
          case askTail of
            (W.VI64 removed : W.VI64 start : W.VI64 stop : W.VStr name : W.VStr value : _) -> do
              let act =
                    Format
                      (fromIntegral start, fromIntegral stop)
                      (T.pack name)
                      (if removed == 0 then Just (markValueOf (T.pack value)) else Nothing)
              case keys of
                [] -> do
                  absorbFormat app (Widget ident) act
                  handlers <- readIORef (app.appWidgetFormats)
                  dispatch (mapM_ ($ act) (Map.lookup ident handlers))
                _ -> do
                  foldRowDocument app (Node ident) (keyPath keys) (foldFormat act)
                  handlers <- readIORef (app.appNodeFormats)
                  dispatch (mapM_ (\h -> h (keyPath keys) act) (Map.lookup ident handlers))
            _ -> return ()
          dispatchLoop app
      | kind == W.occKindTextChanged -> do
          let content = case payload of Just (W.VStr s) -> T.pack s; _ -> ""
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetChanges)
              dispatch (mapM_ ($ content) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeChanges)
              dispatch (mapM_ (\h -> h (keyPath keys) content) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindSubmitted -> do
          let content = case payload of Just (W.VStr s) -> T.pack s; _ -> ""
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetSubmits)
              dispatch (mapM_ ($ content) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeSubmits)
              dispatch (mapM_ (\h -> h (keyPath keys) content) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindToggled -> do
          let checked = case payload of Just (W.VBool b) -> b; _ -> False
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetToggles)
              dispatch (mapM_ ($ checked) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeToggles)
              dispatch (mapM_ (\h -> h (keyPath keys) checked) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindValueChanged -> do
          let v = case payload of Just (W.VF64 x) -> x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetValues)
              dispatch (mapM_ ($ v) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeValues)
              dispatch (mapM_ (\h -> h (keyPath keys) v) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindValueCommitted -> do
          let v = case payload of Just (W.VF64 x) -> x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetCommits)
              dispatch (mapM_ ($ v) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeCommits)
              dispatch (mapM_ (\h -> h (keyPath keys) v) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDateChanged -> do
          let packed = case payload of Just (W.VI64 n) -> n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetDates)
              dispatch (mapM_ ($ dayOfPacked packed) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeDates)
              dispatch (mapM_ (\h -> h (keyPath keys) (dayOfPacked packed)) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindTimeChanged -> do
          let packed = case payload of Just (W.VI64 n) -> n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appWidgetTimes)
              dispatch (mapM_ ($ timeOfDayOfPacked packed) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appNodeTimes)
              dispatch (mapM_ (\h -> h (keyPath keys) (timeOfDayOfPacked packed)) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindCloseRequested -> do
          handlers <- readIORef (app.appCloseRequested)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindWindowClosed -> do
          -- One-shot: the window is gone; both registrations retire
          -- with it.
          modifyIORef' (app.appCloseRequested) (Map.delete ident)
          handlers <- readIORef (app.appWindowClosed)
          modifyIORef' (app.appWindowClosed) (Map.delete ident)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindEntryPopped -> do
          -- One-shot: the entry is gone; both registrations retire
          -- with it.
          modifyIORef' (app.appBackRequested) (Map.delete ident)
          handlers <- readIORef (app.appEntryPopped)
          modifyIORef' (app.appEntryPopped) (Map.delete ident)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindBackRequested -> do
          handlers <- readIORef (app.appBackRequested)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindSheetDismissed -> do
          -- One-shot: the sheet is gone; both registrations retire
          -- with it.
          modifyIORef' (app.appDismissRequested) (Map.delete ident)
          handlers <- readIORef (app.appSheetDismissed)
          modifyIORef' (app.appSheetDismissed) (Map.delete ident)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDismissRequested -> do
          handlers <- readIORef (app.appDismissRequested)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindSectionSelected -> do
          -- NOT one-shot: sections never die, and the user can return any
          -- number of times (ident is the section; the window rides as the
          -- payload).
          handlers <- readIORef (app.appSectionSelected)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindClipboardResult -> do
          -- One-shot like the alert, and the request retires with it.
          -- EMPTY IS THE UNIVERSAL NO and arrives as Nothing, because no
          -- platform says which cause it was.
          handlers <- readIORef (app.appClipboardReads)
          writeIORef (app.appClipboardReads) (Map.delete ident handlers)
          dispatch (mapM_ ($ representationOf clip) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindPasted -> do
          -- A paste rides a click tag verbatim, so it arrives on the ordinary
          -- widget/node split — one record kind, the key path deciding.
          case (representationOf clip, keys) of
            (Nothing, _) -> return ()
            (Just rep, []) -> do
              handlers <- readIORef (app.appWidgetPastes)
              dispatch (mapM_ ($ rep) (Map.lookup ident handlers))
            (Just rep, ks) -> do
              handlers <- readIORef (app.appNodePastes)
              dispatch (mapM_ (\h -> h (keyPath ks) rep) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDropped -> do
          -- A drop rides the same tag with four more words
          -- (docs/dnd-plan.md D1), so it arrives on the ordinary
          -- widget/node split — a stamped copy's landing and a
          -- reorderable row's own drag_ended carry the copy's keys (§4).
          case drop_ of
            Nothing -> return ()
            Just d -> do
              let answer =
                    Dropped
                      { point = (W.dropX d, W.dropY d),
                        operation = operationOf (W.dropOperation d),
                        anchor = keyPath (W.dropAnchor d),
                        before = W.dropBefore d,
                        clip = representationOf (Just (W.dropClip d))
                      }
              case keys of
                [] -> do
                  handlers <- readIORef (app.appWidgetDrops)
                  dispatch (mapM_ ($ answer) (Map.lookup ident handlers))
                ks -> do
                  handlers <- readIORef (app.appNodeDrops)
                  dispatch (mapM_ (\h -> h (keyPath ks) answer) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDragEnded -> do
          case payload of
            Just (W.VI64 mask) -> do
              let answer = operationOf (fromIntegral mask)
              case keys of
                [] -> do
                  handlers <- readIORef (app.appDragEnded)
                  dispatch (mapM_ ($ answer) (Map.lookup ident handlers))
                ks -> do
                  handlers <- readIORef (app.appNodeDragEnded)
                  dispatch (mapM_ (\h -> h (keyPath ks) answer) (Map.lookup ident handlers))
            _ -> return ()
          dispatchLoop app
      | kind == W.occKindFileDialogResult -> do
          -- One-shot like the alert, and the id retires with it. The
          -- parser flattens three values per file into the values slot
          -- (no single Value can carry a list), so they are regrouped
          -- in threes here. EMPTY IS CANCEL.
          let regroup (W.VI64 h : W.VStr n : W.VStr p : rest) =
                PickedFile (fromIntegral h) (T.pack n) p : regroup rest
              regroup _ = []
              files = regroup keys
          handlers <- readIORef (app.appFileDialogHandlers)
          writeIORef (app.appFileDialogHandlers) (Map.delete ident handlers)
          dispatch (mapM_ ($ files) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindAlertResult -> do
          -- The parser boxes the u32 choice as VI64. One-shot: the
          -- registration retires with the result.
          let choice = case payload of
                Just (W.VI64 c) -> fromIntegral c :: Word32
                _ -> 0
          handlers <- readIORef (app.appAlertHandlers)
          writeIORef (app.appAlertHandlers) (Map.delete ident handlers)
          dispatch (mapM_ ($ alertChoiceOfWire choice) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindLinkOpened -> do
          -- ident is the ROUTE the core matched
          -- (docs/app-links-plan.md §4), and NOT one-shot. The parser
          -- flattens the URL and the captured pairs into the values
          -- slot, so they are regrouped in twos after the URL.
          let pairs (W.VStr name : W.VStr value : rest) =
                (T.pack name, T.pack value) : pairs rest
              pairs _ = []
          case keys of
            (W.VStr url : rest) ->
              linkOpened app ident (T.pack url) (Map.fromList (pairs rest))
            _ -> return ()
          dispatchLoop app
      | kind == W.occKindNotificationResult -> do
          -- The parser boxes the u32 outcome as VI64, the alert's own slot.
          notificationResult app ident $ case payload of
            Just (W.VI64 o) -> fromIntegral o :: Word32
            _ -> 0
          dispatchLoop app
      -- The undo pair keys the per-WINDOW tables (ident is the window;
      -- the label rides as the payload). NOT one-shot. THE MODEL IS
      -- RECONCILED FIRST, and unconditionally: the core moved without a
      -- transaction, so an app reading `count` in the handler must see
      -- the restored state.
      | kind == W.occKindUndone || kind == W.occKindRedone -> do
          let delta = maybe emptyUndoDelta id undone
              label = case payload of Just (W.VStr s) -> T.pack s; _ -> ""
          absorbUndo app delta
          handlers <-
            readIORef
              (if kind == W.occKindUndone then app.appUndone else app.appRedone)
          dispatch (mapM_ (\h -> h label delta) (Map.lookup ident handlers))
          dispatchLoop app
      -- Menu occurrences key the menu-item tables — their own id space.
      -- Node-anchored context items carry the stamped copy's keys;
      -- toggles carry the new state, radio groups the new 0-based index.
      | kind == W.occKindMenuActivated -> do
          case keys of
            [] -> do
              handlers <- readIORef (app.appMenuActivated)
              dispatch (mapM_ id (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appMenuActivatedNode)
              dispatch (mapM_ ($ keyPath keys) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindMenuToggled -> do
          let checked = case payload of Just (W.VBool b) -> b; _ -> False
          case keys of
            [] -> do
              handlers <- readIORef (app.appMenuToggled)
              dispatch (mapM_ ($ checked) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appMenuToggledNode)
              dispatch (mapM_ (\h -> h (keyPath keys) checked) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindMenuValueChanged -> do
          let index = case payload of Just (W.VF64 x) -> truncate x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (app.appMenuSelected)
              dispatch (mapM_ ($ index) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (app.appMenuSelectedNode)
              dispatch (mapM_ (\h -> h (keyPath keys) index) (Map.lookup ident handlers))
          dispatchLoop app
    Just (_, ident, [], _, _, _, _, _) -> do
      handlers <- readIORef (app.appWidgetHandlers)
      dispatch (mapM_ id (Map.lookup ident handlers))
      dispatchLoop app
    Just (_, ident, keys, _, _, _, _, _) -> do
      handlers <- readIORef (app.appNodeHandlers)
      dispatch (mapM_ ($ keyPath keys) (Map.lookup ident handlers))
      dispatchLoop app

-- The canvas ask's trailing values: the size the core is asking about,
-- and a tick's frame time in seconds. TIME 0 FOR A PLAIN REDRAW — a
-- ticking canvas is asked once as a draw_requested before its first
-- frame, and the stored function takes the time either way.
askSize :: [W.Value] -> (Viewbox, Double)
askSize (W.VF64 w : W.VF64 h : rest) =
  (Viewbox w h, case rest of W.VF64 t : _ -> t; _ -> 0)
askSize other =
  errorWithoutStackTrace
    ( "kaya: a canvas ask carries "
        ++ show other
        ++ ", wanted the assigned width and height as f64"
    )

-- A dialog is a question: the continuation monad over the callbacks the
-- binding already registers, with the App carried, so a chain reads top to
-- bottom while every step still runs as that callback on the app thread.
-- `build` is the explicit scope after an answer (docs/async-dialogs-plan.md
-- §3). No parallel form: one dialog is live at a time.
type Ask = ReaderT App (ContT () IO)

askWith :: ((a -> IO ()) -> Build ()) -> Ask a
askWith show = do
  app <- Reader.ask
  lift (ContT (\k -> buildTx app (show k)))

askAlert :: [AlertAttr] -> Ask AlertChoice
askAlert attrs = askWith (showAlert attrs)

askPickFiles :: [(Text, Text)] -> Ask [PickedFile]
askPickFiles filters = askWith (pickFiles filters)

askPickFile :: [(Text, Text)] -> Ask [PickedFile]
askPickFile filters = askWith (pickFile filters)

askSaveFile :: Text -> [(Text, Text)] -> Ask (Maybe PickedFile)
askSaveFile name filters = askWith (saveFile name filters)

askReadClipboard :: [Text] -> Ask (Maybe Representation)
askReadClipboard kinds = askWith (readClipboard kinds)

build :: Build a -> Ask a
build b = do
  app <- Reader.ask
  lift (ContT (\k -> buildTx app b >>= k))

runAsk :: App -> Ask () -> IO ()
runAsk app m = evalContT (runReaderT m app)
