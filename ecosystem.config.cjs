const ROOT = __dirname;

module.exports = {
  // plot-oracle-8000 (SNS) removed; duplicate detection delegated to challengers.
  apps: [
    {
      name: 'plot-oracle-3000',
      cwd: `${ROOT}/backend`,
      script: 'node_modules/tsx/dist/cli.mjs',
      args: 'src/index.ts',
      interpreter: 'node',
      env: { NODE_ENV: 'development', PORT: '3000' }
    },
    {
      name: 'plot-oracle-42069',
      cwd: `${ROOT}/indexer`,
      script: 'node_modules/.bin/ponder',
      args: 'dev',
      interpreter: 'node',
      env: { NODE_ENV: 'development', PONDER_PORT: '42069' }
    }
  ]
}
