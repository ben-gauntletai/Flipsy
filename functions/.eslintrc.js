module.exports = {
  root: true,
  env: {
    es6: true,
    node: true,
  },
  extends: [
    "eslint:recommended",
    "plugin:import/errors",
    "plugin:import/warnings",
    "plugin:import/typescript",
    "google",
    "plugin:@typescript-eslint/recommended",
    "prettier",
  ],
  parser: "@typescript-eslint/parser",
  parserOptions: {
    project: ["tsconfig.json", "tsconfig.dev.json"],
    sourceType: "module",
  },
  ignorePatterns: [
    "/lib/**/*", // Ignore built files.
  ],
  plugins: [
    "@typescript-eslint",
    "import",
  ],
  rules: {
    "quotes": ["error", "double"],
    "import/no-unresolved": 0,
    "indent": "off",
    "@typescript-eslint/indent": "off",
    "object-curly-spacing": ["error", "always"],
    "operator-linebreak": "off",
    "max-len": ["error", { "code": 120 }],
    "linebreak-style": "off",
    "require-jsdoc": 0,
    "valid-jsdoc": 0,
    "@typescript-eslint/no-explicit-any": "warn",
    "comma-dangle": ["error", "always-multiline"],
    "arrow-parens": ["error", "always"],
    "brace-style": ["error", "1tbs"],
  },
};
