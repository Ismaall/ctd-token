require('babel-register');
require('babel-polyfill');

module.exports = {
    networks: {
        development: {
            host: "localhost",
            port: 8545,
            network_id: "*" // Match any network id
        }
    },
    gasPrice: 100e9,
    mocha: {
        useColors: false,
        slow: 30000,
        // bail: true,
        grep: "UmuTokenMock",
        invert: true
    },
    version: "0.0.2",
    package_name: "umu-ico",
    description: "Smart-contracts for Umum ICO",
    license: "MIT"
};
