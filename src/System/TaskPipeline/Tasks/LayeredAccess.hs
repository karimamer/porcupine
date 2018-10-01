{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC -Wall #-}

-- | This module provides some utilities for when the pipeline needs to access
-- several files organized in layers for each location in the 'LocationTree'
module System.TaskPipeline.Tasks.LayeredAccess
  ( loadData
  , writeData
  , accessVirtualFile
  , getLocsMappedTo
  , unsafeRunIOTask
  ) where

import           Prelude                            hiding (id, (.))

import           Control.Lens
import           Control.Monad.IO.Class
import qualified Data.HashMap.Strict                as HM
import           Data.Locations
import           Data.Locations.SerializationMethod
import           Katip
import           System.TaskPipeline.ATask
import           System.TaskPipeline.Resource


-- | Uses only the read part of a 'VirtualFile'. It is therefore considered as a
-- pure 'DataSource'. For practical reasons the task input is () rather than
-- Void.
--
-- See 'accessVirtualFile'.
loadData
  :: (LocationMonad m, KatipContext m, Monoid a)
  => VirtualFile ignored a -- ^ A 'DataSource'
  -> ATask m PipelineResource () a  -- ^ The resulting task
loadData vf = arr (const $ error "THIS IS VOID")  -- The input of vf is now Void
          >>> (accessVirtualFile $ vf{vfileSerials = eraseSerials $ vfileSerials vf})

-- | Uses only the write part of a 'VirtualFile'. It is therefore considered as
-- a pure 'DataSink'.
--
-- See 'accessVirtualFile'
writeData
  :: (LocationMonad m, KatipContext m)
  => VirtualFile a ignored  -- ^ A 'DataSink'
  -> ATask m PipelineResource a ()
writeData vf = accessVirtualFile $ vf{vfileSerials = eraseDeserials $ vfileSerials vf}

-- | Writes some data to all the locations bound to a 'VirtualFile' if this
-- 'VirtualFile' has writers, then reads some data over several layers from it
-- (and merges them thanks to a Monoid instance) if this 'VirtualFile' has
-- readers.
--
-- TODO: the list of possible 'DeserializationMethod' should be known
-- statically. We should allow for checking the validity of the deserialization
-- method found in the config before every task is ran.
accessVirtualFile
  :: (LocationMonad m, KatipContext m, Monoid b)
  => VirtualFile a b
  -> ATask m PipelineResource a b
accessVirtualFile vfile =
  liftToATask path (Identity fname') $
    \input (Identity layers) ->
      case layers of
        PRscNothing -> return mempty
        PRscVirtualFile l -> mconcat <$>
          mapM (access input) (l^..locLayers)
        _ -> throwWithPrefix $
          "Unsupported pipeline resource to load.\
          \ Only file paths or 'null' can be used"
  where
    (path, fname) = vpSerialToLTPIs vfile
    fname' = fmap (PRscVirtualFile . WithDefaultUsage (vfileUsedByDefault vfile)) fname
    writers = indexPureSerialsByFileType $ vfileSerials vfile
    readers = indexPureDeserialsByFileType $ vfileSerials vfile
    access input (locWithoutExt, ser) = do
      let loc = addExtToLocIfMissing locWithoutExt ser
      case HM.lookup ser writers of
        Nothing -> return ()
        Just (WriteToLocFn writer) -> do
          writer input loc
          logFM InfoS $ logStr $ "Successfully wrote file '" ++ show loc ++ "'"
      case HM.lookup ser readers of
        Nothing -> return mempty
        Just (ReadFromLocFn reader) -> do
          r <- reader loc
          logFM InfoS $ logStr $ "Successfully loaded file '" ++ show loc ++ "'"
          return r

-- | Returns the locs mapped to some path in the location tree. It *doesn't*
-- expose this path as a requirement (hence the result list may be empty, as no
-- mapping might exist). SHOULD NOT BE USED UNLESS loadDataTask/writeDataTask
-- cannot do what you want.
getLocsMappedTo :: (Monad m) => [LocationTreePathItem] -> ATask m PipelineResource () [Loc]
getLocsMappedTo path = ATask mempty (\(_,tree) -> return (getLocs tree, tree))
  where
    getLocs tree =
      toListOf (atSubfolderRec path . locTreeNodeTag . rscAccessed . pRscVirtualFile . locLayers . _1) tree

-- | Runs an IO action. IT MUST NOT BE PERFORMING READS OR WRITES.
unsafeRunIOTask
  :: (LocationMonad m)
  => (i -> IO o)
  -> ATask m PipelineResource i o
unsafeRunIOTask f = unsafeLiftToATask (liftIO . f)
