export default {
  root: './',
  server: {
    port: 1664,
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  define: {
    'process.env': process.env,
    TextEncoder: 'window.TextEncoder',
    TextDecoder: 'window.TextDecoder',
  },
}
