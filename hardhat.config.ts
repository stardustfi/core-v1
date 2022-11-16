import 'dotenv/config'
import { HardhatUserConfig } from 'hardhat/types'
import 'hardhat-deploy'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-etherscan'
import 'hardhat-contract-sizer'
import '@typechain/hardhat'

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  solidity: {
    compilers: [
      {
        version: '0.5.16',
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
          },
        },
      },
      {
        version: '0.8.13',
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
          },
        },
      },
    ],
  },
  namedAccounts: {
    deployer: {
      hardhat: 0,
      mumbai: '0x4307f766ED0fF932ce3367e1177180FfA647C46D',
      gnosis_chain: '0x4307f766ED0fF932ce3367e1177180FfA647C46D',
      optimism_testnet: '0x4307f766ED0fF932ce3367e1177180FfA647C46D',
      evmos_mainnet: '0x4307f766ED0fF932ce3367e1177180FfA647C46D',
      goerli: '0x4307f766ED0fF932ce3367e1177180FfA647C46D',
    },
    account2: {
      mumbai: '0xA61A62352FAF6AD883A8D36975cf39cDEB477D25',
      gnosis_chain: '0xA61A62352FAF6AD883A8D36975cf39cDEB477D25',
      optimism_testnet: '0xA61A62352FAF6AD883A8D36975cf39cDEB477D25',
      evmos_mainnet: '0xA61A62352FAF6AD883A8D36975cf39cDEB477D25',
      goerli: '0xA61A62352FAF6AD883A8D36975cf39cDEB477D25',
    },
  },
  networks: {
    hardhat: {
      deploy: ['./deploy/testnet'],
    },
    goerli: {
      url: 'https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
      deploy: ['./deploy/testnet'],
      accounts:
        process.env.DEPLOY_PRIVATE_KEY == undefined
          ? []
          : [`0x${process.env.DEPLOY_PRIVATE_KEY}`],
    },
    mumbai: {
      url: `https://polygontestapi.terminet.io/rpc`,
      deploy: ['./deploy/testnet/'],
      accounts:
        process.env.DEPLOY_PRIVATE_KEY == undefined
          ? []
          : [`0x${process.env.DEPLOY_PRIVATE_KEY}`],
    },
    gnosis_chain: {
      url: 'https://rpc.ankr.com/gnosis',
      deploy: ['./deploy/testnet/'],
      accounts:
        process.env.DEPLOY_PRIVATE_KEY == undefined
          ? []
          : [`0x${process.env.DEPLOY_PRIVATE_KEY}`],
    },
    optimism_testnet: {
      url: 'https://goerli.optimism.io',
      deploy: ['./deploy/testnet/'],
      accounts:
        process.env.DEPLOY_PRIVATE_KEY == undefined
          ? []
          : [`0x${process.env.DEPLOY_PRIVATE_KEY}`],
    },
    evmos_mainnet: {
      url: 'https://eth.bd.evmos.org:8545',
      chainId: 9001,
      deploy: ['./deploy/testnet/'],
      accounts:
        process.env.DEPLOY_PRIVATE_KEY == undefined
          ? []
          : [`0x${process.env.DEPLOY_PRIVATE_KEY}`],
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  typechain: {
    outDir: 'types',
    target: 'ethers-v5',
  },
}

export default config
