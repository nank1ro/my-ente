import 'dart:async';
import "dart:convert";
import "dart:math";
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:dio/dio.dart';
import "package:flutter/foundation.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import "package:photos/core/errors.dart";
import 'package:photos/core/event_bus.dart';
import 'package:photos/core/network/network.dart';
import 'package:photos/db/public_keys_db.dart';
import 'package:photos/events/two_factor_status_change_event.dart';
import 'package:photos/events/user_details_changed_event.dart';
import "package:photos/generated/l10n.dart";
import "package:photos/models/api/user/srp.dart";
import 'package:photos/models/delete_account.dart';
import 'package:photos/models/key_attributes.dart';
import 'package:photos/models/key_gen_result.dart';
import 'package:photos/models/public_key.dart' as ePublicKey;
import 'package:photos/models/sessions.dart';
import 'package:photos/models/set_keys_request.dart';
import 'package:photos/models/set_recovery_key_request.dart';
import 'package:photos/models/user_details.dart';
import 'package:photos/ui/account/login_page.dart';
import 'package:photos/ui/account/ott_verification_page.dart';
import 'package:photos/ui/account/password_entry_page.dart';
import 'package:photos/ui/account/password_reentry_page.dart';
import 'package:photos/ui/account/two_factor_authentication_page.dart';
import 'package:photos/ui/account/two_factor_recovery_page.dart';
import 'package:photos/ui/account/two_factor_setup_page.dart';
import 'package:photos/utils/crypto_util.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:photos/utils/navigation_util.dart';
import 'package:photos/utils/toast_util.dart';
import "package:pointycastle/pointycastle.dart";
import "package:pointycastle/srp/srp6_client.dart";
// import "package:pointycastle/srp/srp6_server.dart";
import "package:pointycastle/srp/srp6_standard_groups.dart";
import "package:pointycastle/srp/srp6_util.dart";
import "package:pointycastle/srp/srp6_verifier_generator.dart";
import 'package:shared_preferences/shared_preferences.dart';
import "package:uuid/uuid.dart";

class UserService {
  static const keyHasEnabledTwoFactor = "has_enabled_two_factor";
  static const keyUserDetails = "user_details";
  final _dio = NetworkClient.instance.getDio();
  final _enteDio = NetworkClient.instance.enteDio;
  final _logger = Logger((UserService).toString());
  final _config = Configuration.instance;
  late SharedPreferences _preferences;

  late ValueNotifier<String?> emailValueNotifier;

  UserService._privateConstructor();

  static final UserService instance = UserService._privateConstructor();

  Future<void> init() async {
    emailValueNotifier =
        ValueNotifier<String?>(Configuration.instance.getEmail());
    _preferences = await SharedPreferences.getInstance();
    if (Configuration.instance.isLoggedIn()) {
      // add artificial delay in refreshing 2FA status
      Future.delayed(
        const Duration(seconds: 5),
        () => {setTwoFactor(fetchTwoFactorStatus: true).ignore()},
      );
    }
    Bus.instance.on<TwoFactorStatusChangeEvent>().listen((event) {
      setTwoFactor(value: event.status);
    });
  }

  Future<void> sendOtt(
    BuildContext context,
    String email, {
    bool isChangeEmail = false,
    bool isCreateAccountScreen = false,
  }) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/ott",
        data: {"email": email, "purpose": isChangeEmail ? "change" : ""},
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (BuildContext context) {
                return OTTVerificationPage(
                  email,
                  isChangeEmail: isChangeEmail,
                  isCreateAccountScreen: isCreateAccountScreen,
                );
              },
            ),
          ),
        );
        return;
      }
      unawaited(showGenericErrorDialog(context: context));
    } on DioError catch (e) {
      await dialog.hide();
      _logger.info(e);
      if (e.response != null && e.response!.statusCode == 403) {
        unawaited(
          showErrorDialog(
            context,
            S.of(context).oops,
            S.of(context).thisEmailIsAlreadyInUse,
          ),
        );
      } else {
        unawaited(showGenericErrorDialog(context: context));
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      unawaited(showGenericErrorDialog(context: context));
    }
  }

  Future<void> sendFeedback(
    BuildContext context,
    String feedback, {
    String type = "SubCancellation",
  }) async {
    await _dio.post(
      _config.getHttpEndpoint() + "/anonymous/feedback",
      data: {"feedback": feedback, "type": "type"},
    );
  }

  // getPublicKey returns null value if email id is not
  // associated with another ente account
  Future<String?> getPublicKey(String email) async {
    try {
      final response = await _enteDio.get(
        "/users/public-key",
        queryParameters: {"email": email},
      );
      final publicKey = response.data["publicKey"];
      await PublicKeysDB.instance.setKey(
        ePublicKey.PublicKey(
          email,
          publicKey,
        ),
      );
      return publicKey;
    } on DioError catch (e) {
      if (e.response != null && e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  UserDetails? getCachedUserDetails() {
    if (_preferences.containsKey(keyUserDetails)) {
      return UserDetails.fromJson(_preferences.getString(keyUserDetails)!);
    }
    return null;
  }

  Future<UserDetails> getUserDetailsV2({
    bool memoryCount = true,
    bool shouldCache = false,
  }) async {
    _logger.info("Fetching user details");
    try {
      final response = await _enteDio.get(
        "/users/details/v2",
        queryParameters: {
          "memoryCount": memoryCount,
        },
      );
      final userDetails = UserDetails.fromMap(response.data);
      if (shouldCache) {
        await _preferences.setString(keyUserDetails, userDetails.toJson());
        // handle email change from different client
        if (userDetails.email != _config.getEmail()) {
          setEmail(userDetails.email);
        }
      }
      return userDetails;
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<Sessions> getActiveSessions() async {
    try {
      final response = await _enteDio.get("/users/sessions");
      return Sessions.fromMap(response.data);
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<void> terminateSession(String token) async {
    try {
      await _enteDio.delete(
        "/users/session",
        queryParameters: {
          "token": token,
        },
      );
    } on DioError catch (e) {
      _logger.info(e);
      rethrow;
    }
  }

  Future<void> leaveFamilyPlan() async {
    try {
      await _enteDio.delete("/family/leave");
    } on DioError catch (e) {
      _logger.warning('failed to leave family plan', e);
      rethrow;
    }
  }

  Future<void> logout(BuildContext context) async {
    try {
      final response = await _enteDio.post("/users/logout");
      if (response.statusCode == 200) {
        await Configuration.instance.logout();
        Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        throw Exception("Log out action failed");
      }
    } catch (e) {
      _logger.severe(e);
      //This future is for waiting for the dialog from which logout() is called
      //to close and only then to show the error dialog.
      Future.delayed(
        const Duration(milliseconds: 150),
        () => showGenericErrorDialog(context: context),
      );
      rethrow;
    }
  }

  Future<DeleteChallengeResponse?> getDeleteChallenge(
    BuildContext context,
  ) async {
    try {
      final response = await _enteDio.get("/users/delete-challenge");
      if (response.statusCode == 200) {
        return DeleteChallengeResponse(
          allowDelete: response.data["allowDelete"] as bool,
          encryptedChallenge: response.data["encryptedChallenge"],
        );
      } else {
        throw Exception("delete action failed");
      }
    } catch (e) {
      _logger.severe(e);
      await showGenericErrorDialog(context: context);
      return null;
    }
  }

  Future<void> deleteAccount(
    BuildContext context,
    String challengeResponse, {
    required String reasonCategory,
    required String feedback,
  }) async {
    try {
      final response = await _enteDio.delete(
        "/users/delete",
        data: {
          "challenge": challengeResponse,
          "reasonCategory": reasonCategory,
          "feedback": feedback,
        },
      );
      if (response.statusCode == 200) {
        // clear data
        await Configuration.instance.logout();
      } else {
        throw Exception("delete action failed");
      }
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> verifyEmail(BuildContext context, String ott) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/verify-email",
        data: {
          "email": _config.getEmail(),
          "ott": ott,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        Widget page;
        final String twoFASessionID = response.data["twoFactorSessionID"];
        if (twoFASessionID.isNotEmpty) {
          setTwoFactor(value: true);
          page = TwoFactorAuthenticationPage(twoFASessionID);
        } else {
          await _saveConfiguration(response);
          if (Configuration.instance.getEncryptedToken() != null) {
            page = const PasswordReentryPage();
          } else {
            page = const PasswordEntryPage(mode: PasswordEntryMode.set,);
          }
        }
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return page;
            },
          ),
          (route) => route.isFirst,
        );
      } else {
        // should never reach here
        throw Exception("unexpected response during email verification");
      }
    } on DioError catch (e) {
      _logger.info(e);
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 410) {
        await showErrorDialog(
          context,
          S.of(context).oops,
          S.of(context).yourVerificationCodeHasExpired,
        );
        Navigator.of(context).pop();
      } else {
        showErrorDialog(
          context,
          S.of(context).incorrectCode,
          S.of(context).sorryTheCodeYouveEnteredIsIncorrect,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).verificationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> setEmail(String email) async {
    await _config.setEmail(email);
    emailValueNotifier.value = email;
  }

  Future<void> changeEmail(
    BuildContext context,
    String email,
    String ott,
  ) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    try {
      final response = await _enteDio.post(
        "/users/change-email",
        data: {
          "email": email,
          "ott": ott,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        showShortToast(context, S.of(context).emailChangedTo(email));
        await setEmail(email);
        Navigator.of(context).popUntil((route) => route.isFirst);
        Bus.instance.fire(UserDetailsChangedEvent());
        return;
      }
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).verificationFailedPleaseTryAgain,
      );
    } on DioError catch (e) {
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 403) {
        showErrorDialog(
          context,
          S.of(context).oops,
          S.of(context).thisEmailIsAlreadyInUse,
        );
      } else {
        showErrorDialog(
          context,
          S.of(context).incorrectCode,
          S.of(context).authenticationFailedPleaseTryAgain,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).verificationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> setAttributes(KeyGenResult result) async {
    try {
      await registerSrp(result.loginKey);
      await _enteDio.put(
        "/users/attributes",
        data: {
          "keyAttributes": result.keyAttributes.toMap(),
        },
      );
      await _config.setKey(result.privateKeyAttributes.key);
      await _config.setSecretKey(result.privateKeyAttributes.secretKey);
      await _config.setKeyAttributes(result.keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<SrpAttributes> getSrpAttributes(String email) async {
    final response = await _dio.get( _config.getHttpEndpoint() + "/users/srp/attributes",
      queryParameters: {
        "email": email,
      },
    );
    if (response.statusCode == 200) {
      return SrpAttributes.fromMap(response.data);
    } else {
      throw Exception("get-srp-attributes action failed");
    }
  }

  Future<void> registerSrp(Uint8List loginKey) async {
    try {
      debugPrint("Start srp registering");
      final String username = const Uuid().v4().toString();
      final SecureRandom random = _getSecureRandom();
      final Uint8List identity = Uint8List.fromList(username.codeUnits);
      final Uint8List password = loginKey;
      final Uint8List salt = random.nextBytes(16);
      final gen = SRP6VerifierGenerator(
        group: SRP6StandardGroups.rfc5054_4096,
        digest: Digest('SHA-256'),
      );
      final v = gen.generateVerifier(salt, identity, password);

      final client = SRP6Client(
        group: SRP6StandardGroups.rfc5054_4096,
        digest: Digest('SHA-256'),
        random: random,
      );

      final A = client.generateClientCredentials(salt, identity, password);
      final request = SetupSRPRequest(
        srpUserID: username,
        srpSalt: base64Encode(salt),
        srpVerifier: base64Encode(SRP6Util.encodeBigInt(v)),
        srpA: base64Encode(SRP6Util.encodeBigInt(A!)),
        isUpdate: false,
      );
      final response = await _enteDio.post(
        "/users/srp/setup",
        data: request.toMap(),
      );
      if (response.statusCode == 200) {
        final SetupSRPResponse setupSRPResponse =
            SetupSRPResponse.fromJson(response.data);
        final serverB =
            SRP6Util.decodeBigInt(base64Decode(setupSRPResponse.srpB));
        // ignore: need to calculate secret to get M1, unused_local_variable
        final clientS = client.calculateSecret(serverB);
        final clientM = client.calculateClientEvidenceMessage();
        final CompleteSRPSetupRequest completeSRPSetupRequest =
            CompleteSRPSetupRequest(
          setupID: setupSRPResponse.setupID,
          srpM1: base64Encode(SRP6Util.encodeBigInt(clientM!)),
        );
        final completeResponse = await _enteDio.post(
          "/users/srp/complete",
          data: completeSRPSetupRequest.toMap(),
        );
      } else {
        throw Exception("register-srp action failed");
      }
    } catch (e,s) {
      _logger.severe("failed to register srp" ,e,s);
      rethrow;
    }
  }

  SecureRandom _getSecureRandom() {
    final sGen = Random.secure();
    final random = SecureRandom('Fortuna');
    random.seed(KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => sGen.nextInt(255))),),);
    return random;
  }

  Future<void> verifyEmailViaPassword(BuildContext context,
      SrpAttributes srpAttributes,
      String userPassword,
      )
  async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait,
        isDismissible: true,);
    await dialog.show();
    try {
      final kek = await CryptoUtil.deriveKey(
        utf8.encode(userPassword) as Uint8List,
        CryptoUtil.base642bin(srpAttributes.kekSalt),
        srpAttributes.memLimit,
        srpAttributes.opsLimit,
      ).onError((e, s) {
        _logger.severe('key derivation failed', e, s);
        throw KeyDerivationError();
      });
      final loginKey = await CryptoUtil.deriveLoginKey(kek);
      final Uint8List identity = Uint8List.fromList(srpAttributes.srpUserID.codeUnits);
      final Uint8List salt = base64Decode(srpAttributes.srpSalt);
      final Uint8List password = loginKey;
      final random =_getSecureRandom();

      final client = SRP6Client(
        group: SRP6StandardGroups.rfc5054_4096,
        digest: Digest('SHA-256'),
        random: random,
      );

      final A = client.generateClientCredentials(salt, identity, password);
      final createSessionResponse = await _dio.post(
        _config.getHttpEndpoint() + "/users/srp/create-session",
        data: {
          "srpUserID": srpAttributes.srpUserID,
          "srpA": base64Encode(SRP6Util.encodeBigInt(A!)),
        },
      );
      final String sessionID = createSessionResponse.data["sessionID"];
      final String srpB = createSessionResponse.data["srpB"];

      final serverB = SRP6Util.decodeBigInt(base64Decode(srpB));
      // ignore: need to calculate secret to get M1, unused_local_variable
      final clientS = client.calculateSecret(serverB);
      final clientM = client.calculateClientEvidenceMessage();
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/srp/verify",
        data: {
          "sessionID": sessionID,
          "srpUserID": srpAttributes.srpUserID,
          "srpM1": base64Encode(SRP6Util.encodeBigInt(clientM!)),
        },
      );
      if (response.statusCode == 200) {
        await dialog.hide();
        Widget page;
        final String twoFASessionID = response.data["twoFactorSessionID"];
        Configuration.instance.setVolatilePassword(userPassword);
        if (twoFASessionID.isNotEmpty) {
          setTwoFactor(value: true);
          page = TwoFactorAuthenticationPage(twoFASessionID);
        } else {
          await _saveConfiguration(response);
          if (Configuration.instance.getEncryptedToken() != null) {
            page = const PasswordReentryPage();
          } else {
           throw Exception("unexpected response during email verification");
          }
        }
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return page;
            },
          ),
              (route) => route.isFirst,
        );
      } else {
        // should never reach here
        throw Exception("unexpected response during email verification");
      }
    } on DioError catch (e,s) {
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 401) {
        await showErrorDialog(
          context,
          S.of(context).incorrectPasswordTitle,
          S.of(context).pleaseTryAgain,
        );
      } else {
        _logger.fine('failed to verify password', e,s);
        await showErrorDialog(
          context,
          S.of(context).oops,
          S.of(context).verificationFailedPleaseTryAgain,
        );
      }
    } catch (e,s) {
      _logger.fine('failed to verify password', e,s);
      await dialog.hide();
      await showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).verificationFailedPleaseTryAgain,
      );
    }
  }


  Future<void> updateKeyAttributes(KeyAttributes keyAttributes) async {
    try {
      final setKeyRequest = SetKeysRequest(
        kekSalt: keyAttributes.kekSalt,
        encryptedKey: keyAttributes.encryptedKey,
        keyDecryptionNonce: keyAttributes.keyDecryptionNonce,
        memLimit: keyAttributes.memLimit!,
        opsLimit: keyAttributes.opsLimit!,
      );
      await _enteDio.put(
        "/users/keys",
        data: setKeyRequest.toMap(),
      );
      await _config.setKeyAttributes(keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> setRecoveryKey(KeyAttributes keyAttributes) async {
    try {
      final setRecoveryKeyRequest = SetRecoveryKeyRequest(
        keyAttributes.masterKeyEncryptedWithRecoveryKey!,
        keyAttributes.masterKeyDecryptionNonce!,
        keyAttributes.recoveryKeyEncryptedWithMasterKey!,
        keyAttributes.recoveryKeyDecryptionNonce!,
      );
      await _enteDio.put(
        "/users/recovery-key",
        data: setRecoveryKeyRequest.toMap(),
      );
      await _config.setKeyAttributes(keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<void> verifyTwoFactor(
    BuildContext context,
    String sessionID,
    String code,
  ) async {
    final dialog = createProgressDialog(context, S.of(context).authenticating);
    await dialog.show();
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/two-factor/verify",
        data: {
          "sessionID": sessionID,
          "code": code,
        },
      );
      await dialog.hide();
      if (response.statusCode == 200) {
        showShortToast(context, S.of(context).authenticationSuccessful);
        await _saveConfiguration(response);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const PasswordReentryPage();
            },
          ),
          (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      await dialog.hide();
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, "Session expired");
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
          (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          S.of(context).incorrectCode,
          S.of(context).authenticationFailedPleaseTryAgain,
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.severe(e);
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).authenticationFailedPleaseTryAgain,
      );
    }
  }

  Future<void> recoverTwoFactor(BuildContext context, String sessionID) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    try {
      final response = await _dio.get(
        _config.getHttpEndpoint() + "/users/two-factor/recover",
        queryParameters: {
          "sessionID": sessionID,
        },
      );
      if (response.statusCode == 200) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return TwoFactorRecoveryPage(
                sessionID,
                response.data["encryptedSecret"],
                response.data["secretDecryptionNonce"],
              );
            },
          ),
          (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, S.of(context).sessionExpired);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
          (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          S.of(context).oops,
          S.of(context).somethingWentWrongPleaseTryAgain,
        );
      }
    } catch (e) {
      _logger.severe(e);
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).somethingWentWrongPleaseTryAgain,
      );
    } finally {
      await dialog.hide();
    }
  }

  Future<void> removeTwoFactor(
    BuildContext context,
    String sessionID,
    String recoveryKey,
    String encryptedSecret,
    String secretDecryptionNonce,
  ) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    String secret;
    try {
      if (recoveryKey.contains(' ')) {
        if (recoveryKey.split(' ').length != mnemonicKeyWordCount) {
          throw AssertionError(
            'recovery code should have $mnemonicKeyWordCount words',
          );
        }
        recoveryKey = bip39.mnemonicToEntropy(recoveryKey);
      }
      secret = CryptoUtil.bin2base64(
        await CryptoUtil.decrypt(
          CryptoUtil.base642bin(encryptedSecret),
          CryptoUtil.hex2bin(recoveryKey.trim()),
          CryptoUtil.base642bin(secretDecryptionNonce),
        ),
      );
    } catch (e) {
      await dialog.hide();
      await showErrorDialog(
        context,
        S.of(context).incorrectRecoveryKey,
        S.of(context).theRecoveryKeyYouEnteredIsIncorrect,
      );
      return;
    }
    try {
      final response = await _dio.post(
        _config.getHttpEndpoint() + "/users/two-factor/remove",
        data: {
          "sessionID": sessionID,
          "secret": secret,
        },
      );
      if (response.statusCode == 200) {
        showShortToast(
          context,
          S.of(context).twofactorAuthenticationSuccessfullyReset,
        );
        await _saveConfiguration(response);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const PasswordReentryPage();
            },
          ),
          (route) => route.isFirst,
        );
      }
    } on DioError catch (e) {
      _logger.severe(e);
      if (e.response != null && e.response!.statusCode == 404) {
        showToast(context, "Session expired");
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LoginPage();
            },
          ),
          (route) => route.isFirst,
        );
      } else {
        showErrorDialog(
          context,
          S.of(context).oops,
          S.of(context).somethingWentWrongPleaseTryAgain,
        );
      }
    } catch (e) {
      _logger.severe(e);
      showErrorDialog(
        context,
        S.of(context).oops,
        S.of(context).somethingWentWrongPleaseTryAgain,
      );
    } finally {
      await dialog.hide();
    }
  }

  Future<void> setupTwoFactor(BuildContext context, Completer completer) async {
    final dialog = createProgressDialog(context, S.of(context).pleaseWait);
    await dialog.show();
    try {
      final response = await _enteDio.post("/users/two-factor/setup");
      await dialog.hide();
      unawaited(
        routeToPage(
          context,
          TwoFactorSetupPage(
            response.data["secretCode"],
            response.data["qrCode"],
            completer,
          ),
        ),
      );
    } catch (e) {
      await dialog.hide();
      _logger.severe("Failed to setup tfa", e);
      completer.complete();
      rethrow;
    }
  }

  Future<bool> enableTwoFactor(
    BuildContext context,
    String secret,
    String code,
  ) async {
    Uint8List recoveryKey;
    try {
      recoveryKey = await getOrCreateRecoveryKey(context);
    } catch (e) {
      showGenericErrorDialog(context: context);
      return false;
    }
    final dialog = createProgressDialog(context, S.of(context).verifying);
    await dialog.show();
    final encryptionResult =
        CryptoUtil.encryptSync(CryptoUtil.base642bin(secret), recoveryKey);
    try {
      await _enteDio.post(
        "/users/two-factor/enable",
        data: {
          "code": code,
          "encryptedTwoFactorSecret":
              CryptoUtil.bin2base64(encryptionResult.encryptedData!),
          "twoFactorSecretDecryptionNonce":
              CryptoUtil.bin2base64(encryptionResult.nonce!),
        },
      );
      await dialog.hide();
      Navigator.pop(context);
      Bus.instance.fire(TwoFactorStatusChangeEvent(true));
      return true;
    } catch (e, s) {
      await dialog.hide();
      _logger.severe(e, s);
      if (e is DioError) {
        if (e.response != null && e.response!.statusCode == 401) {
          showErrorDialog(
            context,
            S.of(context).incorrectCode,
            S.of(context).pleaseVerifyTheCodeYouHaveEntered,
          );
          return false;
        }
      }
      showErrorDialog(
        context,
        S.of(context).somethingWentWrong,
        S.of(context).pleaseContactSupportIfTheProblemPersists,
      );
    }
    return false;
  }

  Future<void> disableTwoFactor(BuildContext context) async {
    final dialog = createProgressDialog(
      context,
      S.of(context).disablingTwofactorAuthentication,
    );
    await dialog.show();
    try {
      await _enteDio.post(
        "/users/two-factor/disable",
      );
      await dialog.hide();
      Bus.instance.fire(TwoFactorStatusChangeEvent(false));
      unawaited(
        showShortToast(
          context,
          S.of(context).twofactorAuthenticationHasBeenDisabled,
        ),
      );
    } catch (e) {
      await dialog.hide();
      _logger.severe("Failed to disabled 2FA", e);
      await showErrorDialog(
        context,
        S.of(context).somethingWentWrong,
        S.of(context).pleaseContactSupportIfTheProblemPersists,
      );
    }
  }

  Future<bool> fetchTwoFactorStatus() async {
    try {
      final response = await _enteDio.get("/users/two-factor/status");
      setTwoFactor(value: response.data["status"]);
      return response.data["status"];
    } catch (e) {
      _logger.severe("Failed to fetch 2FA status", e);
      rethrow;
    }
  }

  Future<Uint8List> getOrCreateRecoveryKey(BuildContext context) async {
    final String? encryptedRecoveryKey =
        _config.getKeyAttributes()!.recoveryKeyEncryptedWithMasterKey;
    if (encryptedRecoveryKey == null || encryptedRecoveryKey.isEmpty) {
      final dialog = createProgressDialog(context, S.of(context).pleaseWait);
      await dialog.show();
      try {
        final keyAttributes = await _config.createNewRecoveryKey();
        await setRecoveryKey(keyAttributes);
        await dialog.hide();
      } catch (e, s) {
        await dialog.hide();
        _logger.severe(e, s);
        rethrow;
      }
    }
    final recoveryKey = _config.getRecoveryKey();
    return recoveryKey;
  }

  Future<String?> getPaymentToken() async {
    try {
      final response = await _enteDio.get("/users/payment-token");
      if (response.statusCode == 200) {
        return response.data["paymentToken"];
      } else {
        throw Exception("non 200 ok response");
      }
    } catch (e) {
      _logger.severe("Failed to get payment token", e);
      return null;
    }
  }

  Future<String> getFamiliesToken() async {
    try {
      final response = await _enteDio.get("/users/families-token");
      if (response.statusCode == 200) {
        return response.data["familiesToken"];
      } else {
        throw Exception("non 200 ok response");
      }
    } catch (e, s) {
      _logger.severe("failed to fetch families token", e, s);
      rethrow;
    }
  }

  Future<void> _saveConfiguration(Response response) async {
    await Configuration.instance.setUserID(response.data["id"]);
    if (response.data["encryptedToken"] != null) {
      await Configuration.instance
          .setEncryptedToken(response.data["encryptedToken"]);
      await Configuration.instance.setKeyAttributes(
        KeyAttributes.fromMap(response.data["keyAttributes"]),
      );
    } else {
      await Configuration.instance.setToken(response.data["token"]);
    }
  }

  Future<void> setTwoFactor({
    bool value = false,
    bool fetchTwoFactorStatus = false,
  }) async {
    if (fetchTwoFactorStatus) {
      value = await UserService.instance.fetchTwoFactorStatus();
    }
    _preferences.setBool(keyHasEnabledTwoFactor, value);
  }

  bool hasEnabledTwoFactor() {
    return _preferences.getBool(keyHasEnabledTwoFactor) ?? false;
  }
}
