{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell, RankNTypes, NamedFieldPuns, RecordWildCards, DoRec, BangPatterns #-}
module Distribution.Server.Features.LegacyPasswds (
    initLegacyPasswdsFeature,
    LegacyPasswdsFeature(..),
  ) where

import Prelude hiding (abs)

import Distribution.Server.Framework
import Distribution.Server.Framework.Templating
import Distribution.Server.Framework.BackupDump
import Distribution.Server.Framework.BackupRestore

import qualified Distribution.Server.Features.LegacyPasswds.Auth as LegacyAuth

import Distribution.Server.Features.Users

import Distribution.Server.Users.Types
import qualified Distribution.Server.Users.Types as Users
import qualified Distribution.Server.Users.Users as Users
import qualified Distribution.Server.Framework.Auth as Auth

import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import qualified Data.ByteString.Lazy.Char8 as LBS -- ASCII data only (password hashes)

import Data.Typeable (Typeable)
import Data.SafeCopy (base, deriveSafeCopy)
import Control.Monad.Reader (ask)
import Control.Monad.State (get, put)

import Distribution.Text (display)
import Data.Version
import Text.CSV (CSV, Record)
import Network.URI (URI(..), uriToString)


-- | A feature to help porting accounts from the old central
-- hackage.haskell.org server. It is not needed by new installations.
--
data LegacyPasswdsFeature = LegacyPasswdsFeature {
    legacyPasswdsFeatureInterface :: HackageFeature
}

instance IsHackageFeature LegacyPasswdsFeature where
  getFeatureInterface = legacyPasswdsFeatureInterface

-------------------------
-- Types of stored data
--

newtype LegacyPasswdsTable = LegacyPasswdsTable (IntMap LegacyAuth.HtPasswdHash)
  deriving (Eq, Show, Typeable)

emptyLegacyPasswdsTable :: LegacyPasswdsTable
emptyLegacyPasswdsTable = LegacyPasswdsTable IntMap.empty

lookupUserLegacyPasswd :: LegacyPasswdsTable -> UserId -> Maybe LegacyAuth.HtPasswdHash
lookupUserLegacyPasswd (LegacyPasswdsTable tbl) (UserId uid) =
    IntMap.lookup uid tbl

$(deriveSafeCopy 0 'base ''LegacyPasswdsTable)

instance MemSize LegacyPasswdsTable where
    memSize (LegacyPasswdsTable a) = memSize1 a

------------------------------
-- State queries and updates
--

getLegacyPasswdsTable :: Query LegacyPasswdsTable LegacyPasswdsTable
getLegacyPasswdsTable = ask

replaceLegacyPasswdsTable :: LegacyPasswdsTable -> Update LegacyPasswdsTable ()
replaceLegacyPasswdsTable = put

setUserLegacyPasswd :: UserId -> LegacyAuth.HtPasswdHash -> Update LegacyPasswdsTable ()
setUserLegacyPasswd (UserId uid) udetails = do
    LegacyPasswdsTable tbl <- get
    put $! LegacyPasswdsTable (IntMap.insert uid udetails tbl)

deleteUserLegacyPasswd :: UserId -> Update LegacyPasswdsTable Bool
deleteUserLegacyPasswd (UserId uid) = do
    LegacyPasswdsTable tbl <- get
    if IntMap.member uid tbl
      then do put $! LegacyPasswdsTable (IntMap.delete uid tbl)
              return True
      else return False


makeAcidic ''LegacyPasswdsTable [
    --queries
    'getLegacyPasswdsTable,
    --updates
    'replaceLegacyPasswdsTable,
    'setUserLegacyPasswd,
    'deleteUserLegacyPasswd
  ]


---------------------
-- State components
--

legacyPasswdsStateComponent :: FilePath -> IO (StateComponent AcidState LegacyPasswdsTable)
legacyPasswdsStateComponent stateDir = do
  st <- openLocalStateFrom (stateDir </> "db" </> "LegacyPasswds") emptyLegacyPasswdsTable
  return StateComponent {
      stateDesc    = "Support for upgrading accounts from htpasswd-style passwords"
    , stateHandle  = st
    , getState     = query st GetLegacyPasswdsTable
    , putState     = update st . ReplaceLegacyPasswdsTable
    , backupState  = \users -> [csvToBackup ["htpasswd.csv"] (legacyPasswdsToCSV users)]
    , restoreState = legacyPasswdsBackup
    , resetState   = legacyPasswdsStateComponent
    }

----------------------------
-- Data backup and restore
--

legacyPasswdsBackup :: RestoreBackup LegacyPasswdsTable
legacyPasswdsBackup = updatePasswdsBackup []

updatePasswdsBackup :: [(UserId, LegacyAuth.HtPasswdHash)] -> RestoreBackup LegacyPasswdsTable
updatePasswdsBackup upasswds = RestoreBackup {
    restoreEntry = \entry -> case entry of
      BackupByteString ["htpasswd.csv"] bs -> do
        when (not (null upasswds)) (fail "legacyPasswdsBackup: found multiple htpasswd.csv files")
        csv <- importCSV "htpasswd.csv" bs
        upasswds' <- importHtPasswds csv
        return (updatePasswdsBackup upasswds')
      _ ->
        return (updatePasswdsBackup upasswds)
  , restoreFinalize =
      let tbl =  IntMap.fromList [ (uid, htpasswd)
                                 | (UserId uid, htpasswd) <- upasswds ] in
      return $! LegacyPasswdsTable tbl
  }

importHtPasswds :: CSV -> Restore [(UserId, LegacyAuth.HtPasswdHash)]
importHtPasswds = sequence . map fromRecord . drop 2
  where
    fromRecord :: Record -> Restore (UserId, LegacyAuth.HtPasswdHash)
    fromRecord [idStr, htpasswdStr] = do
        uid <- parseText "user id" idStr
        return (uid, LegacyAuth.HtPasswdHash htpasswdStr)

    fromRecord x = fail $ "Error processing user details record: " ++ show x

legacyPasswdsToCSV :: LegacyPasswdsTable -> CSV
legacyPasswdsToCSV (LegacyPasswdsTable tbl)
    = ([display version]:) $
      (headers:) $

      flip map (IntMap.toList tbl) $ \(uid, LegacyAuth.HtPasswdHash passwdhash) ->
      [ display (UserId uid)
      , passwdhash
      ]
 where
    headers = ["uid", "htpasswd"]
    version = Version [0,1] []

----------------------------------------
-- Feature definition & initialisation
--

initLegacyPasswdsFeature :: ServerEnv -> UserFeature -> IO LegacyPasswdsFeature
initLegacyPasswdsFeature env@ServerEnv{serverStateDir, serverTemplatesDir, serverTemplatesMode} users = do

  -- Canonical state
  legacyPasswdsState <- legacyPasswdsStateComponent serverStateDir

  -- Page templates
  templates <- loadTemplates serverTemplatesMode
                 [serverTemplatesDir, serverTemplatesDir </> "LegacyPasswds"]
                 ["htpasswd-upgrade.html", "htpasswd-upgrade-success.html"]

  let feature = legacyPasswdsFeature env legacyPasswdsState templates users

  return feature

legacyPasswdsFeature :: ServerEnv
                     -> StateComponent AcidState LegacyPasswdsTable
                     -> Templates
                     -> UserFeature
                     -> LegacyPasswdsFeature
legacyPasswdsFeature env legacyPasswdsState templates UserFeature{..}
  = LegacyPasswdsFeature {..}

  where
    legacyPasswdsFeatureInterface = (emptyHackageFeature "legacy-passwds") {
        featureDesc      = "Support for upgrading accounts from htpasswd-style passwords"
      , featureResources = [htpasswordResource, htpasswordUpgradeResource]
      , featureState     = [abstractAcidStateComponent legacyPasswdsState]
      , featureCaches    = []
      , featurePostInit  = interceptUserAuthFail
      , featureReloadFiles = reloadTemplates templates
      }

    -- Resources
    --

    htpasswordResource = (resourceAt "/user/:username/htpasswd") {
            resourceDesc = [ (PUT, "Set a legacy password for a user account") ],
            resourcePut  = [ ("", handleUserHtpasswdPut) ]
          }

    htpasswordUpgradeResource = (resourceAt "/users/htpasswd-upgrade") {
            resourceDesc = [ (GET, "Upgrade a user account with a legacy password") ],
            resourceGet  = [ ("html", handleUserAuthUpgradeGet) ],
            resourcePost = [ ("", handleUserAuthUpgradePost) ]
          }

    -- Request handlers
    --

    handleUserAuthUpgradeGet :: DynamicPath -> ServerPartE Response
    handleUserAuthUpgradeGet _ = do
        template <- getTemplate templates "htpasswd-upgrade.html"
        ok $ toResponse $ template []

    queryLegacyPasswds :: MonadIO m => m LegacyPasswdsTable
    queryLegacyPasswds = queryState legacyPasswdsState GetLegacyPasswdsTable

    handleUserHtpasswdPut :: DynamicPath -> ServerPartE Response
    handleUserHtpasswdPut dpath = do
        _            <- guardAuthorised [InGroup adminGroup]
        users        <- queryGetUserDb
        uname        <- userNameInPath dpath
        (uid, uinfo) <- maybe errNoSuchUser return (Users.lookupUserName uname users)
        when (userStatus uinfo /= Users.AccountDisabled Nothing) errHasAuth
        passwdhash   <- expectTextPlain
        when (not $ validHtpasswd passwdhash) errBadHash
        let htpasswd = LegacyAuth.HtPasswdHash (LBS.unpack passwdhash)
        updateState legacyPasswdsState $ SetUserLegacyPasswd uid htpasswd
        noContent $ toResponse ()
      where
        validHtpasswd str = LBS.length str == 13
        errNoSuchUser = errNotFound "No such user" [MText "No such user"]
        errHasAuth    = errBadRequest "Clashing auth details" [MText "The user already has auth info"]
        errBadHash    = errBadRequest "Invalid htpasswd hash" [MText "Only classic htpasswd crypt() passwords are supported."]

    handleUserAuthUpgradePost :: DynamicPath -> ServerPartE Response
    handleUserAuthUpgradePost _ = do
        users              <- queryGetUserDb
        legacyPasswds      <- queryLegacyPasswds
        (uid, uinfo, passwd) <- LegacyAuth.guardAuthenticated
                                  (RealmName "Old Hackage site")
                                  users
                                  (lookupUserLegacyPasswd legacyPasswds)
        when (userStatus uinfo /= Users.AccountDisabled Nothing) errHasAuth
        let auth = Users.UserAuth (Auth.newPasswdHash Auth.hackageRealm (userName uinfo) passwd)
        updateSetUserAuth uid auth
        updateSetUserEnabledStatus uid True
        updateState legacyPasswdsState (DeleteUserLegacyPasswd uid)
        template <- getTemplate templates "htpasswd-upgrade-success.html"
        ok $ toResponse $ template []
      where
        errHasAuth = errForbidden "Cannot set new password"
          [MText $ "The account is not in a state where upgrading the "
                ++ "authentication is allowed. If this is unexpected, "
                ++ "please contact an administrator."]

    interceptUserAuthFail :: IO ()
    interceptUserAuthFail = do
      registerHook authFailHook onAuthFail

    onAuthFail :: Auth.AuthError -> IO (Maybe ErrorResponse)
    -- For the case where a user tries to authenticate as a user who's account
    -- is disabled with no password, we check if that user has a legacy
    -- htpassword. If so, we direct them to a page where they can log in with
    -- the old account details.
    -- Note that we have not authenticated the user yet, so we have to be very
    -- careful about what info we reveal. Technically we are revealing
    -- something here: the fact that the user exists and has an old htpasswd.
    onAuthFail (Auth.UserStatusError uid
                  UserInfo { userStatus = AccountDisabled Nothing }) = do
        legacyPasswds <- queryLegacyPasswds
        case lookupUserLegacyPasswd legacyPasswds uid of
          Nothing -> return Nothing
          Just _  -> return (Just err)
      where
        err = ErrorResponse 403 [] "Account needs to be re-enabled" msg
        msg = [ MText $ "Hackage has been upgraded to use a more secure login "
                     ++ "system. Please go to "
              , MLink abs rel
              , MText $ " to re-enable your account and for more details about "
                     ++ "this change." ]
        rel = renderResource htpasswordUpgradeResource []
        abs = uriToString id ((serverBaseURI env) { uriPath = rel }) ""

    onAuthFail _ = return Nothing

