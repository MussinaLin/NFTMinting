require("@nomicfoundation/hardhat-toolbox");
require('@openzeppelin/hardhat-upgrades');
require('dotenv/config');
require("solidity-coverage");

const wallet = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : undefined
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        compilers: [
            {
                version: "0.8.22",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 10,
                    },
                    viaIR: true
                }
            }
        ]
    },
    networks: {
        hardhat: {
            chainId:1,
            accounts: {
                // mnemonic for testing, DO NOT USE in production
                mnemonic:"comic tag flash ahead scissors concert actress exile tuition shrug exhibit father",
                count: 10,
            }
          },
        localhost: {
            url: 'http://127.0.0.1:8545',
            
        },
        sepolia: {
            url: 'https://sepolia.infura.io/v3/e876de601519478790cf4e8c425d0aee',
            throwOnTransactionFailures: true,  
            throwOnCallFailures: true,
            networkCheckTimeout: 999999,
            timeoutBlocks: 200,
        },
        base: {
            url: 'https://base-rpc.publicnode.com',
            accounts: wallet,
            throwOnTransactionFailures: true,  
            throwOnCallFailures: true, 
        },
    },
    etherscan: {
        apiKey: ""
    },
};
