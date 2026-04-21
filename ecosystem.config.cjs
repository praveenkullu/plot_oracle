module.exports = {
  apps: [
    {
      name: 'plot-oracle-3000',
      cwd: './backend',
      script: 'node_modules/tsx/dist/cli.mjs',
      args: 'src/index.ts',
      interpreter: 'node',
      env: { NODE_ENV: 'development', PORT: '3000' }
    },
    {
      name: 'plot-oracle-8000',
      cwd: './services/sns',
      script: 'start.cjs',
      interpreter: 'node',
      env: { PYTHONUNBUFFERED: '1' }
    },
    {
      name: 'plot-oracle-42069',
      cwd: './indexer',
      script: 'node_modules/.bin/ponder',
      args: 'dev',
      interpreter: 'node',
      env: { NODE_ENV: 'development' }
    }
  ]
}
