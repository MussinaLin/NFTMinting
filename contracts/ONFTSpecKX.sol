// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ECDSAUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import {MerkleProofUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "solmate/src/tokens/ERC20.sol";
import "./MultiMintUtils.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract ONFTSpecKX is MultiMintUtils, ReentrancyGuardUpgradeable {
    /// @dev Record the tokenID,self increase from zero.
    uint256 private _tokenIdCounter;

    /// @dev Address mint record in each stage.
    mapping(address => mapping(string => uint256)) public mintRecord;

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint32 maxSupply,
        string calldata name_,
        string calldata symbol_,
        string calldata baseUri,
        StageMintInfo[] calldata stageMintInfos
    ) public initializer {
        __Ownable_init();
        __ERC721_init(name_, symbol_);
        __EIP712_init("ONFTSpecKX", "1.0");
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        for (uint256 i = 0; i < stageMintInfos.length; ++i) {

            bytes memory nameBytes = bytes(stageToMint[stageMintInfos[i].stage].stage); // Convert string to bytes
            if (nameBytes.length != 0) {
                revert StageAlreadyExist();
            }

            stageToMint[stageMintInfos[i].stage] = stageMintInfos[i];

            _totalStageSupply += stageMintInfos[i].maxSupplyForStage;
        }
        if (_totalStageSupply > maxSupply) {
            revert InvalidConfig();
        }
        globalInfo = GlobalInfo({
            isCheckAllowlist: false,
            isTransferRestricted: false,
            transferStartTime: 0,
            transferEndTime: 0,
            name: name_,
            symbol: symbol_,
            baseUri: baseUri,
            maxSupply: maxSupply
        });
    }
    /**
     * *  Entry   ************************************************
     */
    /**
     * @notice Public Mint.
     *
     * @param stage         Identification of the stage
     * @param signature     Mint signature if mint type is signed.
     * @param proof         The proof for the leaf of the allowlist in a stage if mint type is Allowlist.
     * @param mintparams    The mint parameter
     */

    function mint(
        string calldata stage,
        bytes calldata signature,
        bytes32[] calldata proof,
        MintParams calldata mintparams
    ) external payable nonReentrant {
        StageMintInfo memory stageMintInfo = stageToMint[stage];

        // Ensure that the mint stage status.
        _validateActive(stageMintInfo.startTime, stageMintInfo.endTime);

        //validate mint amount
        uint256 mintedAmount = mintRecord[mintparams.to][stage];
        _validateAmount(
            mintparams.amount,
            mintedAmount,
            stageMintInfo.limitationForAddress,
            stageMintInfo.maxSupplyForStage,
            stageToTotalSupply[stage]
        );

        //validate allowlist merkle proof if mint type is Allowlist
        if (stageMintInfo.mintType == MintType.Allowlist) {
            if (
                !MerkleProofUpgradeable.verify(
                    proof, stageMintInfo.allowListMerkleRoot, keccak256(abi.encodePacked(mintparams.to))
                )
            ) {
                revert InvalidProof();
            }
        }

        //validate sigature if needs
        if (stageMintInfo.enableSig) {
            _validateSignature(
                mintparams.to,
                mintparams.tokenId,
                mintparams.amount,
                mintparams.nonce,
                mintparams.expiry,
                stage,
                signature
            );
        }

        //handle payment
        address payeeAddress = stageMintInfo.payeeAddress;
        if (payeeAddress != address(0) && stageMintInfo.price != 0) {
            _handlePayment(mintparams.amount, stageMintInfo.price, payeeAddress, stageMintInfo.paymentToken);
        }

        //handle mint
        _handleMint(mintparams.to, mintparams.amount, stage);
    }

    /**
     * *  Internal   ************************************************
     */
    function _validateActive(uint256 startTime, uint256 endTime) internal view {
        if (_cast(block.timestamp < startTime) | _cast(block.timestamp > endTime) == 1) {
            // Revert if the stage is not active.
            revert NotActive();
        }
    }

    function _validateAmount(
        uint256 amount,
        uint256 mintedAmount,
        uint256 mintLimitationPerAddress,
        uint256 maxSupplyForStage,
        uint256 stageTotalSupply
    ) internal view {
        //check per address mint limitation
        if (mintedAmount + amount > mintLimitationPerAddress) {
            revert ExceedPerAddressLimit();
        }

        //check stage mint maxsupply
        if (maxSupplyForStage > 0 && stageTotalSupply + amount > maxSupplyForStage) {
            revert ExceedMaxSupplyForStage();
        }

        //check total maxSupply
        if (totalSupply + amount > globalInfo.maxSupply) {
            revert ExceedMaxSupply();
        }
    }

    function _validateSignature(
        address to,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        string calldata stage,
        bytes calldata signature
    ) internal {
        if (block.timestamp > expiry) {
            revert ExpiredSignature();
        }
        bytes32 digest =
            keccak256(abi.encode(MINT_AUTH_TYPE_HASH, to, tokenId, amount, nonce, expiry, keccak256(bytes(stage))));

        if (_usedDigest[digest]) {
            revert UsedSignature();
        }

        address recoveredAddress = ECDSAUpgradeable.recover(_hashTypedDataV4(digest), signature);

        if (!activeSigner[recoveredAddress]) {
            revert InactiveSigner();
        }
        _usedDigest[digest] = true;
    }

    function _handlePayment(uint256 amount, uint256 price, address payeeAddress, address paymentToken) internal {
        if (paymentToken == address(0)) {
            // Revert if the tx's value doesn't match the total cost.
            if (msg.value != amount * price) {
                revert IncorrectPayment();
            }
            SafeTransferLib.safeTransferETH(payeeAddress, msg.value);
        } else {
            if (msg.value != 0) {
                revert IncorrectValue();
            }
            if (!_isContract(paymentToken)) {
                revert IncorrectERC20();
            }
            SafeTransferLib.safeTransferFrom(ERC20(paymentToken), msg.sender, payeeAddress, amount * price);
        }
    }

    function _handleMint(address to, uint256 amount, string calldata stage) internal {
        uint256 currentTokenId = _tokenIdCounter;

        stageToTotalSupply[stage] += amount;
        mintRecord[to][stage] += amount;
        _tokenIdCounter += amount;
        totalSupply += amount;

        for (uint256 i = 0; i < amount; ++i) {
            _safeMint(to, currentTokenId);
            ++currentTokenId;
        }
    }

    function _isContract(address account) internal view returns (bool) {
        return (account.code.length > 0);
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        override
    {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
        if (from != address(0) && to != address(0) && globalInfo.isTransferRestricted) {
            if (
                _cast(block.timestamp < globalInfo.transferStartTime)
                    | _cast(block.timestamp > globalInfo.transferEndTime) == 1
            ) {
                // Revert if the transfer is limited.
                revert LimitedTransfer();
            }
        }
        if (globalInfo.isCheckAllowlist) {
            if (_isContract(msg.sender)) {
                if (!senderAllowlist[msg.sender]) {
                    revert NotInAllowlist();
                }
            }
            if (_isContract(to)) {
                if (!recipientAllowlist[to]) {
                    revert NotInAllowlist();
                }
            }
        }
    }
}
