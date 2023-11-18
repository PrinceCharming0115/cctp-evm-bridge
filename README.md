# cctp-money-bridge-contracts

<h2>Compiling</h2>
```forge build --extra-output abi```

<h2>Request payloads</h2>

Before any burns, the user must approve the transfer.
```
const approveTx = await usdcEthContract.methods.approve(
    ETH_TOKEN_MESSENGER_WITH_METADATA_WRAPPER_CONTRACT_ADDRESS, 
    amount).send({gas: approveTxGas})
```

DepositForBurn is for a simple burn and mint to any destination chain, including Noble.
```
depositForBurn(
    uint256 amount,           // all usdc has 6 decimals, so $1 = 10^6 usdc
    uint32 destinationDomain, // domain id the funds will be minted on
    bytes32 mintRecipient,    // address receiving minted tokens on destination domain
    address burnToken,        // address of the token being burned on the source chain
    bytes32 destinationCaller // (optional) address allowed to mint on destination domain
)
```

DepositForBurnIBC is minting on Noble and forwarding to an IBC connected chain.  IBC forwarding metadata can be included in the payload.
```
depositForBurnIBC(
    uint64 channel,                   // channel id to be used when ibc forwarding
    bytes32 destinationBech32Prefix,  // bech32 prefix used for address encoding once ibc forwarded
    bytes32 destinationRecipient,     // address of the recipient after the IBC forward
    uint256 amount,                   // all usdc has 6 decimals
    bytes32 mintRecipient,            // address receiving minted tokens on destination domain
    address burnToken,                // address of the token being burned on the source chain
    bytes32 destinationCaller,        // (optional) address allowed to mint on destination domain
    bytes calldata memo               // memo to include in the message
)
```

FastTransfer is a faster, custodial version of depositForBurn.
```
fastTransfer(
    uint256 amount,           // all usdc has 6 decimals, so $1 = 10^6 usdc
    uint32 destinationDomain, // domain id the funds will be minted on
    bytes32 mintRecipient,    // address receiving minted tokens on destination domain
    address burnToken,        // address of the token being burned on the source chain
)
```

FastTransferIBC is a faster, custodial version of depositForBurnIBC.  For fast, custodial transfers to a chain connected to Noble via IBC.
```
fastTransferIBC(
        uint256 amount,                       // amount of tokens to burn
        bytes32 recipient,                    // address of fallback mint recipient on Noble
        address token,                        // address of contract to burn deposited tokens, on local domain
        uint64 channel,                       // channel id to be used when ibc forwarding
        bytes32 destinationBech32Prefix,      // bech32 prefix used for address encoding once ibc forwarded
        bytes32 destinationRecipient,         // address of recipient once ibc forwarded
        bytes calldata memo                   // arbitrary memo to be included when ibc forwarding
)
```


TODO: Burn on Noble \
TODO: Burn on Cosmos chain, ibc forward, burn on Noble
