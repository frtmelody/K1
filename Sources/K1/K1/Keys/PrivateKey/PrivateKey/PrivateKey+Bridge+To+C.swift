//
//  File.swift
//  
//
//  Created by Alexander Cyon on 2022-01-27.
//

import secp256k1

extension Bridge {
    
    static func ecdsaSign(
        message: [UInt8],
        privateKey: SecureBytes,
        mode: ECDSASignature.SigningMode
    ) throws -> Data {
        
        guard message.count == K1.Curve.Field.byteCount else {
            throw K1.Error.incorrectByteCountOfMessageToECDSASign
        }
        
        if let nonceFunctionArbitraryData = mode.nonceFunctionArbitraryData {
            guard nonceFunctionArbitraryData.count == 32 else {
                throw K1.Error.incorrectByteCountOfArbitraryDataForNonceFunction
            }
        }
        
        var nonceFunctionArbitraryBytes: [UInt8]? = nil
        if let nonceFunctionArbitraryData = mode.nonceFunctionArbitraryData {
            guard nonceFunctionArbitraryData.count == K1.Curve.Field.byteCount else {
                throw K1.Error.incorrectByteCountOfArbitraryDataForNonceFunction
            }
            nonceFunctionArbitraryBytes = [UInt8](nonceFunctionArbitraryData)
        }
                
        var signatureBridgedToC = secp256k1_ecdsa_recoverable_signature()
        
        try Self.call(
            ifFailThrow: .failedToECDSASignDigest
        ) { context in
            secp256k1_ecdsa_sign_recoverable(
                context,
                &signatureBridgedToC,
                message,
                privateKey.backing.bytes,
                secp256k1_nonce_function_rfc6979,
                nonceFunctionArbitraryBytes
            )
        }
        var recid : Int32 = 0
        var sigData :Array<UInt8> = Array(repeating: 0, count: 65)
        try Self.call(
            ifFailThrow: .failedToECDSASignDigest
        ) { context in
            secp256k1_ecdsa_recoverable_signature_serialize_compact(
                context,
                &sigData,
                &recid,
                &signatureBridgedToC
            )
        }
        sigData[64] = UInt8(recid)
        return Data(
            bytes: sigData,
            count: 65
        )
    }
    
    static func schnorrSign(
        message: [UInt8],
        privateKey: SecureBytes,
        input: SchnorrInput?
    ) throws -> Data {
        guard message.count == K1.Curve.Field.byteCount else {
            throw K1.Error.failedToSchnorrSignMessageInvalidLength
        }
        var signatureOut = [UInt8](repeating: 0, count: 64)
        
        var keyPair = secp256k1_keypair()

        try Self.call(
            ifFailThrow: .failedToInitializeKeyPairForSchnorrSigning
        ) { context in
            secp256k1_keypair_create(context, &keyPair, privateKey.backing.bytes)
        }
        
        var auxilaryRandomBytes: [UInt8]? = nil
        if let auxilaryRandomData = input?.auxilaryRandomData {
            guard auxilaryRandomData.count == K1.Curve.Field.byteCount else {
                throw K1.Error.failedToSchnorrSignDigestProvidedRandomnessInvalidLength
            }
            auxilaryRandomBytes = [UInt8](auxilaryRandomData)
        }
        
        try Self.call(
            ifFailThrow: .failedToSchnorrSignDigest
        ) { context in
            secp256k1_schnorrsig_sign(
                context,
                &signatureOut,
                message,
                &keyPair,
                auxilaryRandomBytes
            )
        }

        var publicKey = secp256k1_xonly_pubkey()

        try Self.call(
            ifFailThrow: .failedToSchnorrSignErrorGettingPubKeyFromKeyPair
        ) { context in
            secp256k1_keypair_xonly_pub(context, &publicKey, nil, &keyPair)
        }

        try Self.call(
            ifFailThrow: .failedToSchnorrSignDigestDidNotPassVerification
        ) { context in
            secp256k1_schnorrsig_verify(context, &signatureOut, message, message.count, &publicKey)
        }

        return Data(signatureOut)
    }
    
    static func ecdh(
        publicKey publicKeyBytes: [UInt8],
        privateKey: SecureBytes
    ) throws -> Data {

        var publicKeyBridgedToC = secp256k1_pubkey()

        try Self.call(ifFailThrow: .incorrectByteCountOfPublicKey(providedByteCount: publicKeyBytes.count)) { context in
            /* Parse a variable-length public key into the pubkey object. */
            secp256k1_ec_pubkey_parse(
                context,
                &publicKeyBridgedToC,
                publicKeyBytes,
                publicKeyBytes.count
            )
        }

        var sharedPublicPointBytes = [UInt8](
            repeating: 0,
            count: K1.Format.uncompressed.length
        )
        
        try Self.call(
            ifFailThrow: .failedToPerformDiffieHellmanKeyExchange
        ) { context in
            /** Compute an EC Diffie-Hellman secret in constant time
             */
            secp256k1_ecdh(
                context,
                &sharedPublicPointBytes, // output
                &publicKeyBridgedToC, // pubkey
                privateKey.backing.bytes, // seckey
                ecdh_skip_hash_extract_x_and_y, // hashfp
                nil // arbitrary data pointer that is passed through to hashfp
            )
        }
        return Data(sharedPublicPointBytes)
    }
}


public struct SchnorrInput {
    public let auxilaryRandomData: Data
}

public extension K1.PrivateKey {

    func ecdsaSign<D: DataProtocol>(
        hashed message: D,
        mode: ECDSASignature.SigningMode = .default
    ) throws -> ECDSASignature {
        let messageBytes = [UInt8](message)
        let signatureData = try withSecureBytes { (secureBytes: SecureBytes) -> Data in
            try Bridge.ecdsaSign(message: messageBytes, privateKey: secureBytes, mode: mode)
        }

        return try ECDSASignature(
            rawRepresentation: signatureData
        )
    }
    
    func schnorrSign<D: DataProtocol>(
        hashed: D,
        input maybeInput: SchnorrInput? = nil
    ) throws -> SchnorrSignature {
        let message = [UInt8](hashed)
        let signatureData = try withSecureBytes { (secureBytes: SecureBytes) -> Data in
            try Bridge.schnorrSign(message: message, privateKey: secureBytes, input: maybeInput)
        }

        return try SchnorrSignature(
            rawRepresentation: signatureData
        )
    }

    func ecdsaSign<D: Digest>(
        digest: D,
        mode: ECDSASignature.SigningMode = .default
    ) throws -> ECDSASignature {
        try ecdsaSign(hashed: Array(digest), mode: mode)
    }
    
    func ecdsaSign<D: DataProtocol>(
        unhashed data: D,
        mode: ECDSASignature.SigningMode = .default
    ) throws -> ECDSASignature {
        try ecdsaSign(digest: SHA256.hash(data: data), mode: mode)
    }
    
    
    func schnorrSign<D: Digest>(
        digest: D,
        input maybeInput: SchnorrInput? = nil
    ) throws -> SchnorrSignature {
        try schnorrSign(hashed: Array(digest), input: maybeInput)
    }
    
    func schnorrSign<D: DataProtocol>(
        unhashed data: D,
        input maybeInput: SchnorrInput? = nil
    ) throws -> SchnorrSignature {
        try schnorrSign(digest: SHA256.hash(data: data), input: maybeInput)
    }
    
  
    func sign<S: ECSignatureScheme, D: DataProtocol>(
        hashed: D,
        scheme: S.Type,
        mode: S.Signature.SigningMode
    ) throws -> S.Signature {
        try S.Signature.by(signing: hashed, with: self, mode: mode)
    }
    
    func sign<S: ECSignatureScheme>(
        digest: S.HashDigest,
        scheme: S.Type,
        mode: S.Signature.SigningMode
    ) throws -> S.Signature {
        try S.Signature.by(signing: Array(digest), with: self, mode: mode)
    }
    
      func sign<S: ECSignatureScheme, D: DataProtocol>(
          unhashed: D,
          scheme: S.Type,
          mode: S.Signature.SigningMode
      ) throws -> S.Signature {
          try sign(
            hashed: Data(S.hash(unhashed: unhashed)),
            scheme: scheme,
            mode: mode
          )
      }
    
    /// Performs a key agreement with provided public key share.
    ///
    /// - Parameter publicKeyShare: The public key to perform the ECDH with.
    /// - Returns: Returns the public point obtain by performing EC mult between
    ///  this `privateKey` and `publicKeyShare`
    /// - Throws: An error occurred while computing the shared secret
    func sharedSecret(with publicKeyShare: K1.PublicKey) throws -> Data {
        let sharedSecretData = try withSecureBytes { secureBytes in
            try Bridge.ecdh(publicKey: publicKeyShare.uncompressedRaw, privateKey: secureBytes)
        }
        return sharedSecretData
    }
}
