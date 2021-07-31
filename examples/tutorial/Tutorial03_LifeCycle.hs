{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Tutorial03_LifeCycle where

import Control.Lens
import Data.Text (Text)
import Monomer
import TextShow

import qualified Data.Text as T
import qualified Monomer.Lens as L

data ListItem = ListItem {
  _ts :: Int,
  _text :: Text
} deriving (Eq, Show)

data AppModel = AppModel {
  _newItemText :: Text,
  _items :: [ListItem]
} deriving (Eq, Show)

data AppEvent
  = AppInit
  | AddItem
  | RemoveItem Int
  deriving (Eq, Show)

makeLenses 'ListItem
makeLenses 'AppModel

buildUI
  :: WidgetEnv AppModel AppEvent
  -> AppModel
  -> WidgetNode AppModel AppEvent
buildUI wenv model = widgetTree where
  listItem idx item = vstack [
      label_ (item ^. text) [ellipsis] `styleBasic` [textSize 12, paddingH 8],
      spacer,
      hstack [
        textField (items . singular (ix idx) . text),
        spacer,
        button "Delete" (RemoveItem idx)
      ]
    ] `key` showt (item ^. ts) `styleBasic` [paddingT 10]

  widgetTree = vstack [
      keystroke [("Enter", AddItem)] $ hstack [
        label "Description:",
        spacer,
        textField_ newItemText [placeholder "Write here!"] `key` "description",
        spacer,
        button "Add" AddItem
          `styleBasic` [paddingH 5]
          `enabled` (model ^. newItemText /= "")
      ],

      separatorLine `styleBasic` [paddingT 20, paddingB 10],

      vstack (zipWith listItem [0..] (model ^. items))
    ] `styleBasic` [padding 20]

handleEvent
  :: WidgetEnv AppModel AppEvent
  -> WidgetNode AppModel AppEvent
  -> AppModel
  -> AppEvent
  -> [AppEventResponse AppModel AppEvent]
handleEvent wenv node model evt = case evt of
  AppInit -> []
  AddItem
    | model ^. newItemText /= "" -> [
      Model $ model
        & newItemText .~ ""
        & items .~ newItem : model ^. items,
      setFocusOnKey wenv "description"]
  RemoveItem idx -> [Model $ model
    & items .~ removeIdx idx (model ^. items)]
  _ -> []
  where
    newItem = ListItem (wenv ^. L.timestamp) (model ^. newItemText)

removeIdx idx lst = part1 ++ drop 1 part2 where
  (part1, part2) = splitAt idx lst

main03 :: IO ()
main03 = do
  startApp model handleEvent buildUI config
  where
    config = [
      appWindowTitle "Tutorial 03 - Merging",
      appTheme darkTheme,
      appFontDef "Regular" "./assets/fonts/Roboto-Regular.ttf",
      appInitEvent AppInit
      ]
    model = AppModel {
      _newItemText = "",
      _items = []
    }
