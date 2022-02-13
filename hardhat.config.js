require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers"); 
const private_key = require("./keys/privatekey.json");

const PRIVATE_KEY = private_key.key;

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: "0.8.11",
};