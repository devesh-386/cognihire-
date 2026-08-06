export const metadata = {
  title: "CogniHire — Interview",
  description: "Candidate interview portal",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily: "system-ui, -apple-system, Segoe UI, Roboto, sans-serif",
          background: "#0b1220",
          color: "#e7ecf3",
          minHeight: "100vh",
        }}
      >
        {children}
      </body>
    </html>
  );
}
