import type { Metadata, Viewport } from "next";
import "./globals.css";
import "./brand.css";

export const metadata: Metadata = {
  title: "My Storage Locks | Lock Manager",
  description: "Facility lock inventory and assignments",
  robots: { index: false, follow: false },
  icons: {
    icon: [
      { url: "/favicon.svg", type: "image/svg+xml" },
      { url: "/favicon-32.png", sizes: "32x32", type: "image/png" },
    ],
    apple: "/apple-touch-icon.png",
  },
  manifest: "/manifest.webmanifest",
};
export const viewport: Viewport = { themeColor: "#252D36" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}
