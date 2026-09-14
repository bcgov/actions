import { baseConfig } from '../eslint.config.js'

export default [
  ...baseConfig,
  {
    rules: {
      'no-unused-vars': 'warn',
      'no-undef': 'error'
    }
  }
]
