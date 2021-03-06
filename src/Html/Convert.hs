{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE MagicHash                  #-}

module Html.Convert where

import Data.Word
import Data.Proxy
import Data.String
import GHC.TypeLits

import Html.Type
import GHC.Prim (Addr#, ord#, indexCharOffAddr#)
import GHC.Types

import Data.Char (ord)

import qualified GHC.CString    as GHC
import qualified Data.Monoid    as M
import qualified Data.Semigroup as S

import qualified Data.ByteString.Builder          as B
import qualified Data.ByteString.Builder.Prim     as BP
import qualified Data.ByteString.Builder.Internal as U

import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T

import qualified Data.Text.Lazy              as TL
import qualified Data.Text.Lazy.Encoding     as TL

{-# INLINE escapeUtf8 #-}
escapeUtf8 :: BP.BoundedPrim Char
escapeUtf8 =
    BP.condB (>  '>' ) BP.charUtf8 $
    BP.condB (== '<' ) (fixed4 ('&',('l',('t',';')))) $
    BP.condB (== '>' ) (fixed4 ('&',('g',('t',';')))) $
    BP.condB (== '&' ) (fixed5 ('&',('a',('m',('p',';'))))) $
    BP.condB (== '"' ) (fixed5 ('&',('#',('3',('4',';'))))) $
    BP.condB (== '\'') (fixed5 ('&',('#',('3',('9',';'))))) $
    BP.liftFixedToBounded BP.char7
  where
    {-# INLINE fixed4 #-}
    fixed4 x = BP.liftFixedToBounded $ const x BP.>$<
      BP.char7 BP.>*< BP.char7 BP.>*< BP.char7 BP.>*< BP.char7

    {-# INLINE fixed5 #-}
    fixed5 x = BP.liftFixedToBounded $ const x BP.>$<
      BP.char7 BP.>*< BP.char7 BP.>*< BP.char7 BP.>*< BP.char7 BP.>*< BP.char7

{-# INLINE escape #-}
escape :: BP.BoundedPrim Word8
escape =
    BP.condB (>  c2w '>' ) (BP.liftFixedToBounded BP.word8) $
    BP.condB (== c2w '<' ) (fixed4 (c2w '&',(c2w 'l',(c2w 't',c2w ';')))) $
    BP.condB (== c2w '>' ) (fixed4 (c2w '&',(c2w 'g',(c2w 't',c2w ';')))) $
    BP.condB (== c2w '&' ) (fixed5 (c2w '&',(c2w 'a',(c2w 'm',(c2w 'p',c2w ';'))))) $
    BP.condB (== c2w '"' ) (fixed5 (c2w '&',(c2w '#',(c2w '3',(c2w '4',c2w ';'))))) $
    BP.condB (== c2w '\'') (fixed5 (c2w '&',(c2w '#',(c2w '3',(c2w '9',c2w ';'))))) $
    BP.liftFixedToBounded BP.word8
  where
    c2w = fromIntegral . ord

    fixed4 x = BP.liftFixedToBounded $ const x BP.>$<
      BP.word8 BP.>*< BP.word8 BP.>*< BP.word8 BP.>*< BP.word8

    fixed5 x = BP.liftFixedToBounded $ const x BP.>$<
      BP.word8 BP.>*< BP.word8 BP.>*< BP.word8 BP.>*< BP.word8 BP.>*< BP.word8

newtype Converted = Converted {unConv :: B.Builder} deriving (M.Monoid,S.Semigroup)

instance IsString Converted where
  fromString = convert

{-| Convert a type efficienctly to different string like types.  Add
  instances if you want use custom types in your document.

@
{\-\# LANGUAGE RecordWildCards \#-\}
{\-\# LANGUAGE OverloadedStrings \#-\}

module Main where

import Html

import Data.Text (Text)
import Data.Monoid

data Person
  = Person
  { name :: Text
  , age :: Int
  , vegetarian :: Bool
  }

-- | This is already very efficient.
-- Wrap the Strings in Raw if you don't want to escape them.
instance Convert Person where
  convert (Person{..})
    =  convert name
    <> " is "
    <> convert age
    <> " years old and likes "
    <> if vegetarian then "oranges." else "meat."

john :: Person
john = Person {name = "John", age = 52, vegetarian = True}

main :: IO ()
main = print (div_ john)
@
-}
class Convert a where
  convert :: a -> Converted

instance Convert b => Convert (a := b) where
  {-# INLINE convert #-}
  convert (AT x) = convert x
instance Convert (Raw Char) where
  {-# INLINE convert #-}
  convert (Raw c) = Converted (B.charUtf8 c)
instance Convert (Raw String) where
  {-# INLINE convert #-}
  convert (Raw x) = stringConvRaw x
instance Convert (Raw T.Text) where
  {-# INLINE convert #-}
  convert (Raw x) = Converted (T.encodeUtf8Builder x)
instance Convert (Raw TL.Text) where
  {-# INLINE convert #-}
  convert (Raw x) = Converted (TL.encodeUtf8Builder x)
instance Convert (Raw B.Builder) where
  {-# INLINE convert #-}
  convert (Raw x) = Converted x
instance Convert Char where
  {-# INLINE convert #-}
  convert = Converted . BP.primBounded escapeUtf8
instance Convert String where
  {-# INLINE convert #-}
  convert = stringConv
instance Convert T.Text where
  {-# INLINE convert #-}
  convert = Converted . T.encodeUtf8BuilderEscaped escape
instance Convert TL.Text where
  {-# INLINE convert #-}
  convert = Converted . TL.encodeUtf8BuilderEscaped escape
instance Convert Int where
  {-# INLINE convert #-}
  convert = Converted . B.intDec
instance Convert Integer where
  {-# INLINE convert #-}
  convert = Converted . B.integerDec
instance Convert Float where
  {-# INLINE convert #-}
  convert = Converted . B.floatDec
instance Convert Double where
  {-# INLINE convert #-}
  convert = Converted . B.doubleDec
instance Convert Word where
  {-# INLINE convert #-}
  convert = Converted . B.wordDec
instance KnownSymbol a => Convert (Proxy a) where
  {-# INLINE convert #-}
  convert = Converted . U.byteStringCopy . fromString . symbolVal

{-# INLINE builderCString# #-}
builderCString# :: Addr# -> Converted
builderCString# addr = Converted $ BP.primUnfoldrBounded escape go 0
  where
    go !i | b /= 0 = Just (fromIntegral b, i+1)
          | otherwise = Nothing
      where
        !b = I# (ord# (at# i))
    at# (I# i#) = indexCharOffAddr# addr i#

{-# INLINE [0] stringConv #-}
stringConv :: String -> Converted
stringConv = Converted . BP.primMapListBounded escapeUtf8

{-# INLINE [0] stringConvRaw #-}
stringConvRaw :: String -> Converted
stringConvRaw = Converted . B.stringUtf8

{-# RULES "CONVERTED literal" forall a.
    stringConv (GHC.unpackCString# a)
      = builderCString# a #-}

{-# RULES "CONVERTED literal raw" forall a.
    stringConvRaw (GHC.unpackCString# a)
      = Converted (U.byteStringCopy (fromString (GHC.unpackCString# a))) #-}

{-# RULES "CONVERTED literal utf8" forall a.
    stringConv (GHC.unpackCStringUtf8# a)
      = convert (T.pack (GHC.unpackCStringUtf8# a)) #-}

{-# RULES "CONVERTED literal utf8 raw" forall a.
    stringConvRaw (GHC.unpackCStringUtf8# a)
      = convert (Raw (T.pack (GHC.unpackCStringUtf8# a))) #-}
