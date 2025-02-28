// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../bridge/IBridge.sol";
import "../libs/LibAddress.sol";
import "./BridgedERC20.sol";
import "./BaseVault.sol";

/// @title ERC20Vault
/// @notice This vault holds all ERC20 tokens (excluding Ether) that users have
/// deposited. It also manages the mapping between canonical ERC20 tokens and
/// their bridged tokens.
/// @dev Labeled in AddressResolver as "erc20_vault".
/// @custom:security-contact security@taiko.xyz
contract ERC20Vault is BaseVault {
    using LibAddress for address;
    using SafeERC20 for IERC20;

    /// @dev Represents a canonical ERC20 token.
    struct CanonicalERC20 {
        uint64 chainId;
        address addr;
        uint8 decimals;
        string symbol;
        string name;
    }

    /// @dev Represents an operation to send tokens to another chain.
    struct BridgeTransferOp {
        uint64 destChainId;
        address destOwner;
        address to;
        address token;
        uint256 amount;
        uint256 gasLimit;
        uint256 fee;
        address refundTo;
        string memo;
    }

    /// @notice Mappings from bridged tokens to their canonical tokens.
    mapping(address btoken => CanonicalERC20 canonical) public bridgedToCanonical;

    /// @notice Mappings from canonical tokens to their bridged tokens. Also storing
    /// the chainId for tokens across other chains aside from Ethereum.
    mapping(uint256 chainId => mapping(address ctoken => address btoken)) public canonicalToBridged;

    /// @notice Mappings from bridged tokens to their blacklist status.
    mapping(address btoken => bool blacklisted) public btokenBlacklist;

    uint256[47] private __gap;

    /// @notice Emitted when a new bridged token is deployed.
    /// @param srcChainId The chain ID of the canonical token.
    /// @param ctoken The address of the canonical token.
    /// @param btoken The address of the bridged token.
    /// @param ctokenSymbol The symbol of the canonical token.
    /// @param ctokenName The name of the canonical token.
    /// @param ctokenDecimal The decimal of the canonical token.
    event BridgedTokenDeployed(
        uint256 indexed srcChainId,
        address indexed ctoken,
        address indexed btoken,
        string ctokenSymbol,
        string ctokenName,
        uint8 ctokenDecimal
    );

    /// @notice Emitted when a bridged token is changed.
    /// @param srcChainId The chain ID of the canonical token.
    /// @param ctoken The address of the canonical token.
    /// @param btokenOld The address of the old bridged token.
    /// @param btokenNew The address of the new bridged token.
    /// @param ctokenSymbol The symbol of the canonical token.
    /// @param ctokenName The name of the canonical token.
    /// @param ctokenDecimal The decimal of the canonical token.
    event BridgedTokenChanged(
        uint256 indexed srcChainId,
        address indexed ctoken,
        address btokenOld,
        address btokenNew,
        string ctokenSymbol,
        string ctokenName,
        uint8 ctokenDecimal
    );

    /// @notice Emitted when a token is sent to another chain.
    /// @param msgHash The hash of the message.
    /// @param from The address of the sender.
    /// @param to The address of the recipient.
    /// @param destChainId The chain ID of the destination chain.
    /// @param ctoken The address of the canonical token.
    /// @param token The address of the bridged token.
    /// @param amount The amount of tokens sent.
    event TokenSent(
        bytes32 indexed msgHash,
        address indexed from,
        address indexed to,
        uint64 destChainId,
        address ctoken,
        address token,
        uint256 amount
    );

    /// @notice Emitted when a token is released from a message.
    /// @param msgHash The hash of the message.
    /// @param from The address of the sender.
    /// @param ctoken The address of the canonical token.
    /// @param token The address of the bridged token.
    /// @param amount The amount of tokens released.
    event TokenReleased(
        bytes32 indexed msgHash, address indexed from, address ctoken, address token, uint256 amount
    );

    /// @notice Emitted when a token is received from another chain.
    /// @param msgHash The hash of the message.
    /// @param from The address of the sender.
    /// @param to The address of the recipient.
    /// @param srcChainId The chain ID of the source chain.
    /// @param ctoken The address of the canonical token.
    /// @param token The address of the bridged token.
    /// @param amount The amount of tokens received.
    event TokenReceived(
        bytes32 indexed msgHash,
        address indexed from,
        address indexed to,
        uint64 srcChainId,
        address ctoken,
        address token,
        uint256 amount
    );

    error VAULT_BTOKEN_BLACKLISTED();
    error VAULT_CTOKEN_MISMATCH();
    error VAULT_INVALID_TOKEN();
    error VAULT_INVALID_AMOUNT();
    error VAULT_INVALID_NEW_BTOKEN();
    error VAULT_INVALID_TO();
    error VAULT_NOT_SAME_OWNER();

    /// @notice Change bridged token.
    /// @param _ctoken The canonical token.
    /// @param _btokenNew The new bridged token address.
    /// @return btokenOld_ The old bridged token address.
    function changeBridgedToken(
        CanonicalERC20 calldata _ctoken,
        address _btokenNew
    )
        external
        nonReentrant
        whenNotPaused
        onlyOwner
        returns (address btokenOld_)
    {
        if (_btokenNew == address(0) || bridgedToCanonical[_btokenNew].addr != address(0)) {
            revert VAULT_INVALID_NEW_BTOKEN();
        }

        if (btokenBlacklist[_btokenNew]) revert VAULT_BTOKEN_BLACKLISTED();

        if (IBridgedERC20(_btokenNew).owner() != owner()) {
            revert VAULT_NOT_SAME_OWNER();
        }

        btokenOld_ = canonicalToBridged[_ctoken.chainId][_ctoken.addr];

        if (btokenOld_ != address(0)) {
            CanonicalERC20 memory ctoken = bridgedToCanonical[btokenOld_];

            // The ctoken must match the saved one.
            if (
                ctoken.decimals != _ctoken.decimals
                    || keccak256(bytes(ctoken.symbol)) != keccak256(bytes(_ctoken.symbol))
                    || keccak256(bytes(ctoken.name)) != keccak256(bytes(_ctoken.name))
            ) revert VAULT_CTOKEN_MISMATCH();

            delete bridgedToCanonical[btokenOld_];
            btokenBlacklist[btokenOld_] = true;

            // Start the migration
            IBridgedERC20(btokenOld_).changeMigrationStatus(_btokenNew, false);
            IBridgedERC20(_btokenNew).changeMigrationStatus(btokenOld_, true);
        }

        bridgedToCanonical[_btokenNew] = _ctoken;
        canonicalToBridged[_ctoken.chainId][_ctoken.addr] = _btokenNew;

        emit BridgedTokenChanged({
            srcChainId: _ctoken.chainId,
            ctoken: _ctoken.addr,
            btokenOld: btokenOld_,
            btokenNew: _btokenNew,
            ctokenSymbol: _ctoken.symbol,
            ctokenName: _ctoken.name,
            ctokenDecimal: _ctoken.decimals
        });
    }

    /// @notice Transfers ERC20 tokens to this vault and sends a message to the
    /// destination chain so the user can receive the same amount of tokens by
    /// invoking the message call.
    /// @param _op Option for sending ERC20 tokens.
    /// @return message_ The constructed message.
    function sendToken(BridgeTransferOp calldata _op)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (IBridge.Message memory message_)
    {
        if (_op.amount == 0) revert VAULT_INVALID_AMOUNT();
        if (_op.token == address(0)) revert VAULT_INVALID_TOKEN();
        if (btokenBlacklist[_op.token]) revert VAULT_BTOKEN_BLACKLISTED();

        (bytes memory data, CanonicalERC20 memory ctoken, uint256 balanceChange) =
            _handleMessage(msg.sender, _op.token, _op.to, _op.amount);

        IBridge.Message memory message = IBridge.Message({
            id: 0, // will receive a new value
            from: address(0), // will receive a new value
            srcChainId: 0, // will receive a new value
            destChainId: _op.destChainId,
            srcOwner: msg.sender,
            destOwner: _op.destOwner != address(0) ? _op.destOwner : msg.sender,
            to: resolve(_op.destChainId, name(), false),
            refundTo: _op.refundTo,
            value: msg.value - _op.fee,
            fee: _op.fee,
            gasLimit: _op.gasLimit,
            data: data,
            memo: _op.memo
        });

        bytes32 msgHash;
        (msgHash, message_) =
            IBridge(resolve("bridge", false)).sendMessage{ value: msg.value }(message);

        emit TokenSent({
            msgHash: msgHash,
            from: message_.srcOwner,
            to: _op.to,
            destChainId: _op.destChainId,
            ctoken: ctoken.addr,
            token: _op.token,
            amount: balanceChange
        });
    }

    /// @inheritdoc IMessageInvocable
    function onMessageInvocation(bytes calldata _data)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        (CanonicalERC20 memory ctoken, address from, address to, uint256 amount) =
            abi.decode(_data, (CanonicalERC20, address, address, uint256));

        // `onlyFromBridge` checked in checkProcessMessageContext
        IBridge.Context memory ctx = checkProcessMessageContext();

        // Don't allow sending to disallowed addresses.
        // Don't send the tokens back to `from` because `from` is on the source chain.
        if (to == address(0) || to == address(this)) revert VAULT_INVALID_TO();

        // Transfer the ETH and the tokens to the `to` address
        address token = _transferTokens(ctoken, to, amount);
        to.sendEtherAndVerify(msg.value);

        emit TokenReceived({
            msgHash: ctx.msgHash,
            from: from,
            to: to,
            srcChainId: ctx.srcChainId,
            ctoken: ctoken.addr,
            token: token,
            amount: amount
        });
    }

    /// @inheritdoc IRecallableSender
    function onMessageRecalled(
        IBridge.Message calldata _message,
        bytes32 _msgHash
    )
        external
        payable
        override
        nonReentrant
        whenNotPaused
    {
        // `onlyFromBridge` checked in checkRecallMessageContext
        checkRecallMessageContext();

        (bytes memory data) = abi.decode(_message.data[4:], (bytes));
        (CanonicalERC20 memory ctoken,,, uint256 amount) =
            abi.decode(data, (CanonicalERC20, address, address, uint256));

        // Transfer the ETH and tokens back to the owner
        address token = _transferTokens(ctoken, _message.srcOwner, amount);
        _message.srcOwner.sendEtherAndVerify(_message.value);

        emit TokenReleased({
            msgHash: _msgHash,
            from: _message.srcOwner,
            ctoken: ctoken.addr,
            token: token,
            amount: amount
        });
    }

    /// @inheritdoc BaseVault
    function name() public pure override returns (bytes32) {
        return "erc20_vault";
    }

    function _transferTokens(
        CanonicalERC20 memory _ctoken,
        address _to,
        uint256 _amount
    )
        private
        returns (address token_)
    {
        if (_ctoken.chainId == block.chainid) {
            token_ = _ctoken.addr;
            IERC20(token_).safeTransfer(_to, _amount);
        } else {
            token_ = _getOrDeployBridgedToken(_ctoken);
            IBridgedERC20(token_).mint(_to, _amount);
        }
    }

    /// @dev Handles the message on the source chain and returns the encoded
    /// call on the destination call.
    /// @param _user The user's address.
    /// @param _token The token address.
    /// @param _to To address.
    /// @param _amount Amount to be sent.
    /// @return msgData_ Encoded message data.
    /// @return ctoken_ The canonical token.
    /// @return balanceChange_ User token balance actual change after the token
    /// transfer. This value is calculated so we do not assume token balance
    /// change is the amount of token transferred away.
    function _handleMessage(
        address _user,
        address _token,
        address _to,
        uint256 _amount
    )
        private
        returns (bytes memory msgData_, CanonicalERC20 memory ctoken_, uint256 balanceChange_)
    {
        // If it's a bridged token
        if (bridgedToCanonical[_token].addr != address(0)) {
            ctoken_ = bridgedToCanonical[_token];
            IBridgedERC20(_token).burn(msg.sender, _amount);
            balanceChange_ = _amount;
        } else {
            // If it's a canonical token
            IERC20Metadata meta = IERC20Metadata(_token);
            ctoken_ = CanonicalERC20({
                chainId: uint64(block.chainid),
                addr: _token,
                decimals: meta.decimals(),
                symbol: meta.symbol(),
                name: meta.name()
            });

            // Query the balance then query it again to get the actual amount of
            // token transferred into this address, this is more accurate than
            // simply using `amount` -- some contract may deduct a fee from the
            // transferred amount.
            IERC20 t = IERC20(_token);
            uint256 _balance = t.balanceOf(address(this));
            t.safeTransferFrom({ from: msg.sender, to: address(this), value: _amount });
            balanceChange_ = t.balanceOf(address(this)) - _balance;
        }

        msgData_ = abi.encodeCall(
            this.onMessageInvocation, abi.encode(ctoken_, _user, _to, balanceChange_)
        );
    }

    /// @dev Retrieve or deploy a bridged ERC20 token contract.
    /// @param ctoken CanonicalERC20 data.
    /// @return btoken Address of the bridged token contract.
    function _getOrDeployBridgedToken(CanonicalERC20 memory ctoken)
        private
        returns (address btoken)
    {
        btoken = canonicalToBridged[ctoken.chainId][ctoken.addr];

        if (btoken == address(0)) {
            btoken = _deployBridgedToken(ctoken);
        }
    }

    /// @dev Deploy a new BridgedERC20 contract and initialize it.
    /// This must be called before the first time a bridged token is sent to
    /// this chain.
    /// @param ctoken CanonicalERC20 data.
    /// @return btoken Address of the deployed bridged token contract.
    function _deployBridgedToken(CanonicalERC20 memory ctoken) private returns (address btoken) {
        bytes memory data = abi.encodeCall(
            BridgedERC20.init,
            (
                owner(),
                addressManager,
                ctoken.addr,
                ctoken.chainId,
                ctoken.decimals,
                ctoken.symbol,
                ctoken.name
            )
        );

        btoken = address(new ERC1967Proxy(resolve("bridged_erc20", false), data));
        bridgedToCanonical[btoken] = ctoken;
        canonicalToBridged[ctoken.chainId][ctoken.addr] = btoken;

        emit BridgedTokenDeployed({
            srcChainId: ctoken.chainId,
            ctoken: ctoken.addr,
            btoken: btoken,
            ctokenSymbol: ctoken.symbol,
            ctokenName: ctoken.name,
            ctokenDecimal: ctoken.decimals
        });
    }
}
