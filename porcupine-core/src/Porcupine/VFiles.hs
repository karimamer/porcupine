module Porcupine.VFiles
  ( VirtualFile(..), VFileImportance(..)
  , BidirVirtualFile, DataSource, DataSink
  , LocationTreePathItem
  , Store
  , documentedFile
  , usesLayeredMapping, canBeUnmapped, unmappedByDefault
  , usesCacherWithIdent
  , clockVFileAccesses
  , bidirVirtualFile, dataSource, dataSink
  , makeSource, makeSink
  , plainTextVFile
  )
where

import           Data.Locations.VirtualFile
import           Data.Store
