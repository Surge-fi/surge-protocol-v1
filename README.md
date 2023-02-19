# Surge Protocol

Foundry project containing Surge Protocol's Solidity smart contracts

## Pre-requisites

* [forge](https://github.com/foundry-rs/foundry) ^0.2.0
* [Surge protocol overview](https://medium.com/surge-fi/introduction-to-surge-protocol-overview-34cc828d7c50)

## Compile
`forge build`

## Test
`forge test`

## Coverage report
`forge coverage`

## For reviewers

* Only the Factory contract is deployed by the protocol deployer. Pool contracts are deployed by users via the Factory.
* PoolLens is not considered in scope of reviews and is not mission critical. It is only meant from off-chain frontend consumption.
* The Factory will be deployed on a number of EVM chains. It should at least be compatible with the top L2s (Optimism and Arbitrum) and the [top 10 EVM chains by TVL](https://defillama.com/chains/EVM).
* Unexpected loss of funds due to the operator role should be considered high severity bugs.
* Loan and collateral contracts are considered by the Pool contracts as trusted, ERC20-compliant and non-rebasing token contracts. It's the users' responsibility to choose pools with valid non-malicious token contracts. This include re-entrancy risk due to external calls to these 2 contracts.
* Pool contracts should be compliant with the ERC20 token standard.
* Lenders and borrowers should never suffer a precision loss higher than 1/1e18 of their expected return.
* Pool deployers should not be able to set parameters that cause the pool to behave unexpectedly at a future date (e.g. causing lenders not to be able to withdraw or borrowers to repay/remove collateral).
