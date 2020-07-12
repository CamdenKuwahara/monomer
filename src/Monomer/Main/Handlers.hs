{-# LANGUAGE FlexibleContexts #-}

module Monomer.Main.Handlers (
  HandlerStep,
  handleWidgetResult,
  handleSystemEvents,
  handleWidgetInit
) where

import Control.Concurrent.Async (async)
import Control.Lens (use, (.=))
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)
import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe
import Data.Sequence (Seq(..), (><))

import qualified Data.Sequence as Seq
import qualified SDL

import Monomer.Event.Core
import Monomer.Event.Keyboard
import Monomer.Event.Types
import Monomer.Main.Types
import Monomer.Main.Util
import Monomer.Graphics.Renderer
import Monomer.Widget.PathContext
import Monomer.Widget.Types
import Monomer.Widget.Util

type HandlerStep s e = (WidgetContext s e, Seq e, WidgetInstance s e)

createEventContext :: Maybe Path -> Maybe Path -> Path -> Path -> SystemEvent -> WidgetInstance s e -> Maybe PathContext
createEventContext latestPressed activeOverlay currentFocus currentTarget systemEvent widgetRoot = case systemEvent of
    -- Keyboard
    KeyAction{}           -> pathEvent currentTarget
    TextInput _           -> pathEvent currentTarget
    -- Clipboard
    Clipboard _           -> pathEvent currentTarget
    -- Mouse/touch
    Click point _ _       -> pointEvent point
    WheelScroll point _ _ -> pointEvent point
    Focus                 -> pathEvent currentTarget
    Blur                  -> pathEvent currentTarget
    Enter point           -> pointEvent point
    Move point            -> pointEvent point
    Leave oldPath _       -> pathEvent oldPath
  where
    pathEvent = Just . makePathCtx
    findStartPath = fromMaybe rootPath activeOverlay
    pathFromPoint point = _widgetFind (_instanceWidget widgetRoot) findStartPath point widgetRoot
    pointEvent point = makePathCtx <$> (pathFromPoint point <|> activeOverlay <|> latestPressed)
    makePathCtx targetPath = PathContext currentFocus targetPath rootPath

handleSystemEvents :: (MonomerM s m) => Renderer m -> WidgetContext s e -> [SystemEvent] -> WidgetInstance s e -> m (HandlerStep s e)
handleSystemEvents renderer wctx systemEvents widgetRoot = foldM reducer (wctx, Seq.empty, widgetRoot) systemEvents where
  reducer (currWctx, currEvents, currWidgetRoot) systemEvent = do
    currentFocus <- use focused

    (wctx2, evts2, wroot2) <- handleSystemEvent renderer currWctx systemEvent currentFocus currentFocus currWidgetRoot
    return (wctx2, currEvents >< evts2, wroot2)

handleSystemEvent :: (MonomerM s m) => Renderer m -> WidgetContext s e -> SystemEvent -> Path -> Path -> WidgetInstance s e -> m (HandlerStep s e)
handleSystemEvent renderer wctx systemEvent currentFocus currentTarget widgetRoot = do
  latestPressed <- use latestPressed
  activeOverlay <- use activeOverlay

  case createEventContext latestPressed activeOverlay currentFocus currentTarget systemEvent widgetRoot of
    Nothing -> return (wctx, Seq.empty, widgetRoot)
    Just ctx -> do
      let widget = _instanceWidget widgetRoot
      let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
      let widgetResult = fromMaybe emptyResult $ _widgetHandleEvent widget wctx ctx systemEvent widgetRoot
      let stopProcessing = isJust $ Seq.findIndexL isIgnoreParentEvents (_resultRequests widgetResult)

      handleWidgetResult renderer wctx ctx widgetResult
        >>= handleFocusChange renderer ctx systemEvent stopProcessing

handleWidgetInit :: (MonomerM s m) => Renderer m -> WidgetContext s e -> WidgetInstance s e -> m (HandlerStep s e)
handleWidgetInit renderer wctx widgetRoot = do
  let widget = _instanceWidget widgetRoot
  let ctx = PathContext rootPath rootPath rootPath
  let widgetResult = _widgetInit widget wctx ctx widgetRoot

  handleWidgetResult renderer wctx ctx widgetResult

handleWidgetResult :: (MonomerM s m) => Renderer m -> WidgetContext s e -> PathContext -> WidgetResult s e -> m (HandlerStep s e)
handleWidgetResult renderer wctx ctx (WidgetResult eventRequests appEvents evtRoot) = do
  let evtStates = getUpdateUserStates eventRequests
  let evtApp = foldr (.) id evtStates (_wcApp wctx)
  let evtWctx = wctx { _wcApp = evtApp }

  handleNewWidgetTasks eventRequests

  handleFocusSet renderer eventRequests (evtWctx, appEvents, evtRoot)
    >>= handleClipboardGet renderer ctx eventRequests
    >>= handleClipboardSet renderer eventRequests
    >>= handleSendMessages renderer eventRequests
    >>= handleOverlaySet renderer eventRequests
    >>= handleOverlayReset renderer eventRequests

handleFocusChange :: (MonomerM s m) => Renderer m -> PathContext -> SystemEvent -> Bool -> HandlerStep s e -> m (HandlerStep s e)
handleFocusChange renderer ctx systemEvent stopProcessing (app, events, widgetRoot)
  | focusChangeRequested = do
      oldFocus <- use focused
      (newApp1, newEvents1, newRoot1) <- handleSystemEvent renderer app Blur oldFocus oldFocus widgetRoot

      let newFocus = findNextFocusable oldFocus widgetRoot
      (newApp2, newEvents2, newRoot2) <- handleSystemEvent renderer newApp1 Focus newFocus newFocus newRoot1
      focused .= newFocus

      return (newApp2, events >< newEvents1 >< newEvents2, widgetRoot)
  | otherwise = return (app, events, widgetRoot)
  where
    focusChangeRequested = not stopProcessing && isKeyPressed systemEvent keyTab

handleFocusSet :: (MonomerM s m) => Renderer m -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleFocusSet renderer eventRequests previousStep =
  case Seq.filter isSetFocus eventRequests of
    SetFocus newFocus :<| _ -> do
      focused .= newFocus

      return previousStep
    _ -> return previousStep

handleClipboardGet :: (MonomerM s m) => Renderer m -> PathContext -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleClipboardGet renderer ctx eventRequests previousStep = do
    hasText <- SDL.hasClipboardText
    contents <- if hasText
                  then fmap ClipboardText SDL.getClipboardText
                  else return ClipboardEmpty

    foldM (reducer contents) previousStep eventRequests
  where
    reducer contents (app, events, widgetRoot) (GetClipboard path) = do
      (newApp2, newEvents2, newRoot2) <- handleSystemEvent renderer app (Clipboard contents) (_pathCurrent ctx) path widgetRoot

      return (newApp2, events >< newEvents2, newRoot2)
    reducer contents previousStep _ = return previousStep

handleClipboardSet :: (MonomerM s m) => Renderer m -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleClipboardSet renderer eventRequests previousStep =
  case Seq.filter isSetClipboard eventRequests of
    SetClipboard (ClipboardText text) :<| _ -> do
      SDL.setClipboardText text

      return previousStep
    _ -> return previousStep

handleOverlaySet :: (MonomerM s m) => Renderer m -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleOverlaySet renderer eventRequests previousStep =
  case Seq.filter isSetOverlay eventRequests of
    SetOverlay path :<| _ -> do
      activeOverlay .= Just path

      return previousStep
    _ -> return previousStep

handleOverlayReset :: (MonomerM s m) => Renderer m -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleOverlayReset renderer eventRequests previousStep =
  case Seq.filter isSetOverlay eventRequests of
    ResetOverlay :<| _ -> do
      activeOverlay .= Nothing

      return previousStep
    _ -> return previousStep

handleSendMessages :: (MonomerM s m) => Renderer m -> Seq (WidgetRequest s) -> HandlerStep s e -> m (HandlerStep s e)
handleSendMessages renderer eventRequests previousStep = foldM reducer previousStep eventRequests where
  reducer previousStep (SendMessage path message) = do
    currentFocus <- use focused

    let (wctx, events, widgetRoot) = previousStep
    let ctx = PathContext currentFocus path rootPath
    let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
    let widgetResult = fromMaybe emptyResult $ _widgetHandleMessage (_instanceWidget widgetRoot) wctx ctx message widgetRoot

    (newWctx, newEvents, newWidgetRoot) <- handleWidgetResult renderer wctx ctx widgetResult

    return (newWctx, events >< newEvents, newWidgetRoot)
  reducer previousStep _ = return previousStep

handleNewWidgetTasks :: (MonomerM s m) => Seq (WidgetRequest s) -> m ()
handleNewWidgetTasks eventRequests = do
  let taskHandlers = Seq.filter isTaskHandler eventRequests
  let producerHandlers = Seq.filter isProducerHandler eventRequests

  singleTasks <- forM taskHandlers $ \(RunTask path handler) -> do
    asyncTask <- liftIO $ async (liftIO handler)
    return $ WidgetTask path asyncTask

  producerTasks <- forM producerHandlers $ \(RunProducer path handler) -> do
    newChannel <- liftIO newTChanIO
    asyncTask <- liftIO $ async (liftIO $ handler (sendMessage newChannel))
    return $ WidgetProducer path newChannel asyncTask

  previousTasks <- use widgetTasks
  widgetTasks .= previousTasks >< singleTasks >< producerTasks

sendMessage :: TChan e -> e -> IO ()
sendMessage channel message = atomically $ writeTChan channel message
