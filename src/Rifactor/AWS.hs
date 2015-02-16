{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- Module      : Rifactor.AWS
-- Copyright   : (c) 2015 Knewton, Inc <se@knewton.com>
--               (c) 2015 Tim Dysinger <tim@dysinger.net> (contributor)
-- License     : Apache 2.0 http://opensource.org/licenses/Apache-2.0
-- Maintainer  : Tim Dysinger <tim@dysinger.net>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Rifactor.AWS where

import           BasePrelude
import           Control.Lens
import qualified Control.Monad.Trans.AWS as AWS
import           Control.Monad.Trans.AWS hiding (Empty,Env)
import qualified Data.ByteString.Char8 as B
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.AWS.Data as AWS
import qualified Network.AWS.EC2 as EC2
import           Network.AWS.EC2 hiding (Instance,Region)
import           Rifactor.Types

default (Text)

{- Amazon Environments -}

noKeysEnv :: IO AwsEnv
noKeysEnv =
  Env <$>
  AWS.getEnv
    NorthVirginia
    (FromKeys (AccessKey B.empty)
              (SecretKey B.empty)) <*>
  pure "noop"

initEnvs :: Config -> Logger -> IO [AwsEnv]
initEnvs cfg lgr =
  for [(a,r) | r <- cfg ^. regions
             , a <- cfg ^. accounts]
      (\(Account n k s,r) ->
         Env <$>
         (AWS.getEnv
            r
            (FromKeys (AccessKey (T.encodeUtf8 k))
                      (SecretKey (T.encodeUtf8 s))) <&>
          (envLogger .~ lgr)) <*>
         pure n)

{- Amazon API Queries -}

checkPendingModifications :: [AwsEnv] -> AWS ()
checkPendingModifications =
  traverse_ (\e ->
               runAWST (e ^. eEnv)
                       (do rims <-
                             view drimrReservedInstancesModifications <$>
                             send (describeReservedInstancesModifications &
                                   (drimFilters .~
                                    [filter' "status" &
                                     fValues .~
                                     [T.pack "processing"]]))
                           if null rims
                              then pure ()
                              else error "There are pending RI modifications."))

fetchFromAmazon :: [AwsEnv] -> AWS AwsPlan
fetchFromAmazon es =
  do insts <- fetchInstances es
     rsrvs <- fetchReserved es
     pure (case insts ++ rsrvs of
             [] -> Noop
             is -> Plans (map Item is))

fetchInstances :: [AwsEnv] -> AWS [AwsResource]
fetchInstances =
  liftA concat .
  traverse (\e ->
              runAWST (e ^. eEnv)
                      (view dirReservations <$>
                       send (describeInstances & di1Filters .~
                             [filter' "instance-state-name" &
                              fValues .~
                              [AWS.toText ISNRunning]])) >>=
              hoistEither >>=
              pure .
              map (Instance e) .
              concatMap (view rInstances))

fetchReserved :: [AwsEnv] -> AWS [AwsResource]
fetchReserved =
  liftA concat .
  traverse (\e ->
              runAWST (e ^. eEnv)
                      (view drirReservedInstances <$>
                       send (describeReservedInstances & driFilters .~
                             [filter' "state" &
                              fValues .~
                              [AWS.toText RISActive]])) >>=
              hoistEither >>=
              pure .
              map (Reserved e))

{- AWS Plan Queries -}

typeSet :: AwsPlan -> Set InstanceType
typeSet = foldr f Set.empty
  where f (Reserved _ _) b = b
        f (Instance _ i) b =
          Set.insert (i ^. i1InstanceType)
                     b

regionSet  :: AwsPlan -> Set Region
regionSet = foldr f Set.empty
  where f (Reserved e _) b =
          Set.insert (e ^. eEnv ^. envRegion)
                     b
        f (Instance e _) b =
          Set.insert (e ^. eEnv ^. envRegion)
                     b

zoneSet  :: AwsPlan -> Set Text
zoneSet =
  Set.fromList .
  catMaybes .
  toList .
  foldr f Set.empty
  where f (Reserved _ r) b =
          Set.insert (r ^. ri1AvailabilityZone)
                     b
        f (Instance _ i) b =
          Set.insert (i ^. i1Placement ^. pAvailabilityZone)
                     b

instanceNormFactor :: AwsPlan -> Float
instanceNormFactor = foldr f 0
  where f (Instance _ i) b =
          b +
          find1ByType (i ^. i1InstanceType) ^.
          insFactor
        f _ b = b

rInstanceNormFactor :: AwsPlan -> Maybe Float
rInstanceNormFactor = foldr f (Just 0)
  where f (Reserved _ r) b =
          liftA2 (+)
                 b
                 (liftA2 (*)
                         (fmap realToFrac (r ^. ri1InstanceCount))
                         (fmap (view insFactor)
                               (fmap find1ByType (r ^. ri1InstanceType))))
        f _ b = b

instanceCount :: AwsPlan -> Int
instanceCount m = foldr f 0 m
  where f (Instance _ _) b = b + 1
        f _ b = b

rInstanceCount :: AwsPlan -> Maybe Int
rInstanceCount m = foldr f (Just 0) m
  where f (Reserved _ r) b =
          liftA2 (+) (r ^. ri1InstanceCount) b
        f _ b = b

availableNormFactor :: AwsPlan -> Maybe Float
availableNormFactor p =
  fmap (flip (-) (instanceNormFactor p))
       (rInstanceNormFactor p)

hasCapacityFor :: AwsPlan -> AwsPlan -> Bool
hasCapacityFor p0 p1 =
  let availFactor = availableNormFactor p0
      newFactor = instanceNormFactor p1
  in case fmap (flip (-) newFactor) availFactor of
       Just val -> val >= 0
       Nothing -> False

isInstance :: AwsPlan -> Bool
isInstance = foldr f True
  where f Instance{..} b = b && True
        f _ _ = False

isReserved :: AwsPlan -> Bool
isReserved = foldr f True
  where f Reserved{..} b = b && True
        f _ _ = False

foldEachInstanceWith fn b p0 p1 = foldr f b p0
  where f x@Instance{..} z = foldr (fn x) z p1
        f _ z = z

foldEachReservedWith fn b p0 p1 = foldr f b p0
  where f x@Reserved{..} z = foldr (fn x) z p1
        f _ z = z

appliesTo :: AwsPlan -> AwsPlan -> Bool
appliesTo = foldEachReservedWith isInstanceMatch True

couldSplit :: AwsPlan -> AwsPlan -> Bool
couldSplit = foldEachReservedWith isSplittable True

couldCombine :: AwsPlan -> AwsPlan -> Bool
couldCombine = foldEachReservedWith isCombineable True

isInstanceMatch :: AwsResource -> AwsResource -> Bool -> Bool
isInstanceMatch (Reserved _ r) (Instance _ i) acc =
  acc &&
  -- windows goes with windows
  (((r ^. ri1ProductDescription) `elem`
    [Just RIPDWindows,Just RIPDWindowsAmazonVPC]) ==
   ((i ^. i1Platform) ==
    Just Windows)) &&
  -- vpc goes with vpc
  (((r ^. ri1ProductDescription) `elem`
    [Just RIPDLinuxUNIXAmazonVPC,Just RIPDWindowsAmazonVPC]) ==
   isJust (i ^. i1VpcId)) &&
  -- same instance type
  (r ^. ri1InstanceType == i ^? i1InstanceType) &&
  -- same availability zone
  (r ^. ri1AvailabilityZone == i ^. i1Placement ^. pAvailabilityZone)
isInstanceMatch _ _ _ = False

isSplittable :: AwsResource -> AwsResource -> Bool -> Bool
isSplittable (Reserved er r) (Instance ei i) acc =
  acc &&
  -- windows goes with windows
  (((r ^. ri1ProductDescription) `elem`
    [Just RIPDWindows,Just RIPDWindowsAmazonVPC]) ==
   ((i ^. i1Platform) ==
    Just Windows)) &&
  -- vpc goes with vpc
  (((r ^. ri1ProductDescription) `elem`
    [Just RIPDLinuxUNIXAmazonVPC,Just RIPDWindowsAmazonVPC]) ==
   isJust (i ^. i1VpcId)) &&
  -- same region
  (er ^. eEnv ^. envRegion) ==
  (ei ^. eEnv ^. envRegion)
--     -- and also would fit into this split arrangement
--     let iGroup =
--           find1ByType (i ^. insInst ^. i1InstanceType) ^.
--           insGroup
--         rGroup =
--           fmap (view insGroup . find1ByType)
--                (r ^. split ^. used ^. resResv ^. ri1InstanceType)
--         avail =
--           liftA2 (-)
--                  (capacityTotal r)
--                  (capacityUsed r)
--         factor =
--           find1ByType (i ^. insInst ^. i1InstanceType) ^.
--           insFactor
--     in (Just iGroup ==
--         rGroup) &&
--        case fmap (factor <=) avail of
--          Nothing -> False
--          Just _ -> True
isSplittable _ _ _ = False

isCombineable :: AwsResource -> AwsResource -> Bool -> Bool
isCombineable (Reserved e0 r0) (Reserved e1 r1) acc =
  acc &&
  -- not the same reserved instances
  (r0 ^. ri1ReservedInstancesId /= r1 ^. ri1ReservedInstancesId) &&
  -- but still the same end date
  (r0 ^. ri1End == r1 ^. ri1End) &&
  -- and the same instance type group (C1, M3, etc)
  (find1ByType (r0 ^. ri1InstanceType ^?! _Just) ^.
   insGroup ==
   find1ByType (r1 ^. ri1InstanceType ^?! _Just) ^.
   insGroup) &&
  -- and the same offering type
  (r0 ^. ri1OfferingType == r1 ^. ri1OfferingType) &&
  -- and the same region
  (e0 ^. eEnv ^. envRegion == e1 ^. eEnv ^. envRegion)
isCombineable _ _ _ = False

{- EC2 Instance Type/Group/Factor Table & Lookup -}

find1ByType :: EC2.InstanceType -> IType
find1ByType t =
  head (filter ((==) t . view insType) instanceTypes)

findByGroup :: IGroup -> [IType]
findByGroup g =
  filter ((==) g . view insGroup) instanceTypes

findByFactor :: IGroup -> Float -> [IType]
findByFactor g f =
  filter (\i -> i ^. insGroup == g && i ^. insFactor == f) instanceTypes

instanceTypes :: [IType]
instanceTypes =
  [IType C1 C1_Medium (normFactor Medium)
  ,IType C1 C1_XLarge (normFactor XLarge)
  ,IType C3 C3_2XLarge (normFactor XLarge2X)
  ,IType C3 C3_4XLarge (normFactor XLarge4X)
  ,IType C3 C3_8XLarge (normFactor XLarge8X)
  ,IType C3 C3_Large (normFactor Large)
  ,IType C3 C3_XLarge (normFactor XLarge)
  ,IType C4 C4_2XLarge (normFactor XLarge2X)
  ,IType C4 C4_4XLarge (normFactor XLarge4X)
  ,IType C4 C4_8XLarge (normFactor XLarge8X)
  ,IType C4 C4_Large (normFactor Large)
  ,IType C4 C4_XLarge (normFactor XLarge)
  ,IType CC1 CC1_4XLarge (normFactor XLarge4X)
  ,IType CC2 CC2_8XLarge (normFactor XLarge8X)
  ,IType CG1 CG1_4XLarge (normFactor XLarge4X)
  ,IType CR1 CR1_8XLarge (normFactor XLarge8X)
  ,IType G2 G2_2XLarge (normFactor XLarge2X)
  ,IType HI1 HI1_4XLarge (normFactor XLarge4X)
  ,IType HS1 HS1_8XLarge (normFactor XLarge8X)
  ,IType I2 I2_2XLarge (normFactor XLarge2X)
  ,IType I2 I2_4XLarge (normFactor XLarge4X)
  ,IType I2 I2_8XLarge (normFactor XLarge8X)
  ,IType I2 I2_XLarge (normFactor XLarge)
  ,IType M1 M1_Large (normFactor Large)
  ,IType M1 M1_Medium (normFactor Medium)
  ,IType M1 M1_Small (normFactor Small)
  ,IType M1 M1_XLarge (normFactor XLarge)
  ,IType M2 M2_2XLarge (normFactor XLarge2X)
  ,IType M2 M2_4XLarge (normFactor XLarge4X)
  ,IType M2 M2_XLarge (normFactor XLarge)
  ,IType M3 M3_2XLarge (normFactor XLarge2X)
  ,IType M3 M3_Large (normFactor Large)
  ,IType M3 M3_Medium (normFactor Medium)
  ,IType M3 M3_XLarge (normFactor XLarge)
  ,IType R3 R3_2XLarge (normFactor XLarge2X)
  ,IType R3 R3_4XLarge (normFactor XLarge4X)
  ,IType R3 R3_8XLarge (normFactor XLarge8X)
  ,IType R3 R3_Large (normFactor Large)
  ,IType R3 R3_XLarge (normFactor XLarge)
  ,IType T1 T1_Micro (normFactor Micro)
  ,IType T2 T2_Medium (normFactor Medium)
  ,IType T2 T2_Micro (normFactor Micro)
  ,IType T2 T2_Small (normFactor Small)]

normFactor :: ISize -> Float
normFactor Micro    = 0.5
normFactor Small    = 1
normFactor Medium   = 2
normFactor Large    = 4
normFactor XLarge   = 8
normFactor XLarge2X = 16
normFactor XLarge4X = 32
normFactor XLarge8X = 64
