# pera-staking

![PERA](https://pera.finance/static/media/pera.1355a10261502bfb0871.png)

### Writed in [Solidity 0.8.2](https://docs.soliditylang.org/en/v0.8.2/) and uses [Hardhat](https://hardhat.org/)

<br/>

The contract is designed to be used for staking Pera tokens by giving reward coefficients due to staking time. Pera rewards keeps going for the whole staking period, but new reward tokens can be added for specified periods.

<br/>

The version in ```hacken-audit``` branch is audited by Hacken, see [audit report](https://hacken.io/wp-content/uploads/2022/04/PeraFinance_SCAudit_Report2_05042022.pdf).

<br/>

Download the dependencies by
<br/>

```
npm install --save-dev hardhat
```

```
npm install @openzeppelin/contracts
```

```
npm install --save-dev @nomiclabs/hardhat-ethers ethers @nomiclabs/hardhat-waffle ethereum-waffle chai
```

Put your Alchemy API key for test with Ethereum mainnet fork.
Create ```keys/privatekey.json```  file in your project directory with your private key.

```
{
    "key" : "PRIVATE_KEY"
}
```

<br/>

## File Structure

```
contracts
├──── PeraStaking.sol
├──── MockToken.sol


```