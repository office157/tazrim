/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        navy: {
          950: '#040B1E',
          900: '#070E24',
          800: '#0A1530',
          700: '#0D1B4B',
          600: '#112260',
        },
        teal: {
          DEFAULT: '#00AECC',
          light: '#00C8EB',
          dark: '#0090A8',
        },
        income: '#10B981',
        expense: '#F97316',
      },
      fontFamily: {
        einstein: ['FbEinstein', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
