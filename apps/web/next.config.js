/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  transpilePackages: ['@rallly/database', '@rallly/shared', '@rallly/ui'],
  images: {
    domains: [],
  },
}

module.exports = nextConfig
