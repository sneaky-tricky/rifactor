{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fwarn-auto-orphans #-}

-- Module      : Rifactor.Types
-- Copyright   : (c) 2015 Knewton, Inc <se@knewton.com>
--               (c) 2015 Tim Dysinger <tim@dysinger.net> (contributor)
-- License     : Apache 2.0 http://opensource.org/licenses/Apache-2.0
-- Maintainer  : Tim Dysinger <tim@dysinger.net>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Rifactor.Types where

import Control.Lens (makeLenses)
import Data.Aeson.TH (deriveJSON)
import Network.AWS (Env)
import Network.AWS.EC2.Types (ReservedInstances, Instance)
import Network.AWS.Types (Region)
import Rifactor.Types.Internal (deriveOptions)

data Options =
  PlanOptions {_configFile :: FilePath
              ,_logLevel :: String}

data Account =
  Account {_name :: String
          ,_accessKey :: String
          ,_secretKey :: String}

data Config =
  Config {_accounts :: [Account]
         ,_regions :: [Region]}

data RIEnv =
  RIEnv {_reserved :: [ReservedInstances]
        ,_instances :: [Instance]
        ,_env :: Env}

riEnv :: Env -> RIEnv
riEnv = RIEnv [] []

data Resource
  = UnmatchedInstance {_uiInstance :: Instance}
  | UnmatchedReserved {_urEnv :: Env
                      ,_urReservedInstances :: ReservedInstances}
  | PartialReserved {_prEnv :: Env
                    ,_prReservedInstances :: ReservedInstances
                    ,_prInstances :: [Instance]}
  | UsedReserved {_urEnv :: Env
                 ,_urReservedInstances :: ReservedInstances
                 ,_urInstances :: [Instance]}

{- Lenses -}

$(makeLenses ''Account)
$(makeLenses ''Config)
$(makeLenses ''Options)
$(makeLenses ''Resource)
$(makeLenses ''RIEnv)


{- JSON -}

$(deriveJSON deriveOptions ''Account)
$(deriveJSON deriveOptions ''Config)
$(deriveJSON deriveOptions ''Options)
$(deriveJSON deriveOptions ''Region)
