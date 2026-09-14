import js from '@eslint/js'

export const baseConfig = [
  {
    ignores: ['**/dist/**', '**/lib/**', '**/node_modules/**', '**/.tmp/**']
  },
  js.configs.recommended,
  {
    languageOptions: {
      globals: {
        process: 'readonly',
        console: 'readonly',
        module: 'readonly',
        require: 'readonly'
      }
    }
  }
]

export default baseConfig
