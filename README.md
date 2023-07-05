# Beedle
Oracle free peer to peer perpetual lending

For more in-depth information please see our [documentation]()

# build
`forge init`

`forge install OpenZeppelin/openzeppelin-contracts`

`forge build`

# test
`forge test`

# deploy
first copy the `.example.env` file and create your own `.env` file

`forge script script/LenderScript.s.sol:LenderScript --rpc-url $GOERLI_RPC_URL --broadcast --verify -vvvv`
