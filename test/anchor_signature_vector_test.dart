import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';

/// Cross-language vector for the Fabric chaincode
/// (fabric/chaincode/justiceledger/test/justiceLedger.test.js uses the same
/// values). Signs a manifest hash exactly the way
/// AnchoringService.signAnchor does, with Hardhat's public test account #0,
/// so the chaincode's signer recovery is checked against what the app
/// really produces, not against a JavaScript signer.
void main() {
  const testPrivateKey =
      'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
  const testAddress = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
  // sha256('justice-chain fabric test vector')
  const manifestHash =
      '53f7a63576d0deb96daa84ac541364d061f43190d2a7a4204eeef6ffa49d290e';
  const expectedSignature =
      '727f98f85eb303756a58d66cd6b6195dd812b7a221b760917525ee9b96ea0dd8'
      '4f111e799e0079f6af1cbed11bfb856d5f7bfc3f110c251dd1dd5c124261d14c1b';

  test('anchor signature matches the chaincode test vector', () {
    final key = EthPrivateKey.fromHex(testPrivateKey);
    expect('0x${key.address.toString().toLowerCase()}', testAddress);

    final signature =
        bytesToHex(key.signPersonalMessageToUint8List(hexToBytes(manifestHash)));
    expect(signature, expectedSignature);
  });
}
