{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies #-}
{- HLINT ignore "Redundant bracket" -}
{- HLINT ignore "Avoid lambda using `infix`" -}

-- This is a "procedural language" extension of PostgreSQL
-- allowing the execution of code in Haskell within SQL code.
--
-- Copyright (C) 2023 Edward F. Behn, Jr.
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

-- This module implements functions to allocate memory useing postgres' memory allocation.
-- This prevents memory leaks in case of an ERROR event.

#include "plhaskell.h"

module PGcommon (CallInfo, Datum (Datum), NullableDatum (NullableDatum), Oid (Oid), TypeInfo, getField, palloc, pUseAsCString, pWithArray, pWithArrayLen, pWithCString, voidDatum) where

import Data.ByteString       (ByteString, useAsCStringLen)
import Data.Int              (Int16)
import Foreign.C.String      (CString, CStringLen, withCStringLen)
import Foreign.C.Types       (CBool (CBool), CSize (CSize), CUInt (CUInt))
import Foreign.Marshal.Array (pokeArray)
import Foreign.Marshal.Utils (copyBytes, toBool)
import Foreign.Ptr           (Ptr, WordPtr (WordPtr), nullPtr, ptrToWordPtr)
import Foreign.Storable      (alignment, peek, peekByteOff, peekElemOff, poke, sizeOf, Storable)
import Prelude               (Eq, Int, IO, Maybe (Nothing, Just), Num, String, const, fromIntegral, length, return, undefined, ($), (.), (*), (+))

-- Dummy types to make pointers
data CallInfo
data TypeInfo

newtype Datum = Datum WordPtr deriving newtype (Storable)
newtype Oid = Oid CUInt deriving newtype (Eq, Num, Storable)

voidDatum :: Datum
voidDatum = Datum $ ptrToWordPtr nullPtr

newtype NullableDatum = NullableDatum (Maybe Datum)
instance Storable NullableDatum where
    sizeOf _ = (#size NullableDatum)
    alignment _ = (#alignment NullableDatum)

    peek pNullableDatum = do
        CBool isNull <- (#peek NullableDatum, isnull) pNullableDatum
        if (toBool isNull)
        then return $ NullableDatum Nothing
        else do
            datum <- (#peek NullableDatum, value) pNullableDatum
            return $ NullableDatum $ Just datum

    poke = undefined -- Never used

-- Get field of TypeInfo struct
getField :: Ptr TypeInfo -> Int16 -> IO (Ptr TypeInfo)
getField pTypeInfo j = do
    fields <- (#peek struct TypeInfo, fields) pTypeInfo
    peekElemOff fields $ fromIntegral j

-- Allocate memory using postgres' mechanism
foreign import capi unsafe "postgres.h palloc"
    palloc :: CSize -> IO (Ptr a)

-- Allocate zeroed memory using postgres' mechanism
foreign import capi unsafe "postgres.h palloc0"
    palloc0 :: CSize -> IO (Ptr a)

-- Free memory using postgres' mechanism
foreign import capi unsafe "postgres.h pfree"
    pfree :: Ptr a -> IO ()

pallocArray :: forall a b . Storable a => Int -> (Ptr a -> IO b) -> IO b
pallocArray size action = do
    ptr <- palloc $ fromIntegral $ size * sizeOf (undefined :: a)
    retVal <- action ptr
    pfree ptr
    return retVal

pallocCopy :: CStringLen -> IO CString
pallocCopy (ptr1, len) = do
    ptr2 <- palloc0 ((fromIntegral len) + 1)
    copyBytes ptr2 ptr1 len
    return ptr2

pWithCString :: String -> (CString -> IO b) -> IO b
pWithCString s action = do
    ptr <- withCStringLen s pallocCopy
    retVal <- action ptr
    pfree ptr
    return retVal

pUseAsCString :: ByteString -> (CString -> IO b) -> IO b
pUseAsCString bs action = do
    ptr <- useAsCStringLen bs pallocCopy
    retVal <- action ptr
    pfree ptr
    return retVal

pWithArray :: Storable a => [a] -> (Ptr a -> IO b) -> IO b
pWithArray vals = pWithArrayLen vals . const

pWithArrayLen :: Storable a => [a] -> (Int -> Ptr a -> IO b) -> IO b
pWithArrayLen vals action = do
    let len = length vals
    pallocArray len $ \ptr -> do
        pokeArray ptr vals
        action len ptr