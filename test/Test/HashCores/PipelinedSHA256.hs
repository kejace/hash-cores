{-# LANGUAGE BinaryLiterals            #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE NoStarIsType              #-}

{-# OPTIONS_GHC -fno-warn-missing-monadfail-instances #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise       #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}

module Test.HashCores.PipelinedSHA256 where

import           Data.ByteString                       as B
import qualified Data.ByteString.Char8                 as B8
import           Data.Kind                             (Type)
import           Data.Maybe                            (fromMaybe)
import           Data.Proxy
import qualified Prelude                               as P
import           System.Environment                    (setEnv)

import           Clash.Prelude
import           Clash.Prelude.Testbench

import           Clash.HashCores.Class.Circuit
import           Clash.HashCores.Class.Iterable
import           Clash.HashCores.Class.Paddable
import           Clash.HashCores.Composition.Pipelined
import           Clash.HashCores.Cores
import           Clash.HashCores.Hash.SHA256           as SHA256

import           Test.SmallCheck.Series                as SC
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck                 as QC
import           Test.Tasty.SmallCheck                 as SC

import           Test.HashCores.SHA256                 (SingleBlock (..),
                                                        nativeSHA256)

-- | Arbitrary small naturals
instance Arbitrary SomeNat where
  arbitrary = do
    nat' <- choose (0,10)
    case someNatVal nat' of
      Just nat -> return nat
      Nothing  -> error "choose (0,10) != nat??"

instance Arbitrary SomeSHA256 where
  arbitrary = do
    foldDelay  <- arbitrary
    finalDelay <- arbitrary
    return $ someSHA256 foldDelay finalDelay

instance Monad m => Serial m SomeNat where
  series = do
    nat' <- SC.generate $ \d -> P.map (fromIntegral) [0..d]
    case someNatVal nat' of
      Just nat -> return nat
      Nothing  -> error "series generated a non-natural number"

instance Monad m => Serial m SomeSHA256 where
  series = do
    foldDelay  <- series
    finalDelay <- series
    return $ someSHA256 foldDelay finalDelay

-- | TODO/XXX: refactor / clean up
isZero
  :: SomeSHA256
  -> Bool
isZero (SomeSHA256 sha256) = go sha256
  where
    go :: forall p1 p2 .  (KnownNat p1, KnownNat p2)
       => SHA256 p1 p2 -> Bool
    go _ = (snatToInteger (SNat @p1) == 0) && (snatToInteger (SNat @p2) == 0)

-- | TODO/XXX: refactor / clean up
runSomeSHA
  :: SomeSHA256
  -> ( forall p1 p2 .
       (KnownNat p1, KnownNat p2)
       => SHA256 p1 p2
       -> a
       -> b
  )
  -> a
  -> b
runSomeSHA(SomeSHA256 sha256) go = go sha256

-- | TODO/XXX: refactor / clean up
pipelinedSample' :: forall p1 p2 .
                 ( KnownNat p1, KnownNat p2)
                 => SHA256 p1 p2 -> SingleBlock -> Maybe (BitVector 256)
pipelinedSample' sha =
    case u1 of
      UZero -> case u2 of
        UZero   -> const Nothing
        USucc _ -> Just . pipelinedSample sha
      USucc _ -> Just . pipelinedSample sha
  where
    u1 = toUNat (SNat @p1)
    u2 = toUNat (SNat @p2)

-- | TODO/XXX: refactor / clean up
pipelinedSample :: forall p1 p2 .
                ( KnownNat p1, KnownNat p2
                , 1 <= ((2 * p1) + p2)
                , 1 <= (64*((2 * p1) + p2))
                )
                => SHA256 p1 p2 -> SingleBlock -> BitVector 256
pipelinedSample sha input = sampled
  where
    core
      :: ( HiddenClockResetEnable domain )
      => DSignal domain 0 (BitVector 512)
      -> DSignal domain (0 + (64 * ((2 * p1) + p2))) (BitVector 256)
    core x = fst $ mkCircuit (SimpleCore Pipelined sha) (fmap (,()) x)

    timing = 64*(2*(snatToNum (SNat @p1))+snatToNum (SNat @p2))

    sampled = P.head . P.drop timing . simulate @System (toSignal.core.fromSignal)
            $ processed:P.repeat 0

    processed = pad sha . unsingleBlock $ input

qcProps = testGroup "(checked by QuickCheck)"
  [ QC.testProperty "Hashes random single block" $
      \sha x ->
        case runSomeSHA sha pipelinedSample' x of
          Nothing -> discard
          Just v  -> v == nativeSHA256 x
  ]

scProps = testGroup "(checked by SmallCheck)"
  [ SC.testProperty "Hash 'The quick brown fox jumps over the lazy dog'" $
      \sha -> not (isZero sha) SC.==>
        runSomeSHA sha pipelinedSample' tqbf == Just (nativeSHA256 tqbf)
  ]
  where
    tqbf = SingleBlock (B8.pack "The quick brown fox jumps over the lazy dog")

properties :: TestTree
properties = testGroup "Properties" [qcProps, scProps]

-- | SHA-256 @0 @0 will be ignored or discarded
tests = testGroup "Pipelined :. SHA-256 @X @Y" [properties]
