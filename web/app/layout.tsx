import "./globals.css";
import type { Metadata } from "next";
import { Inter, Plus_Jakarta_Sans } from "next/font/google";

// The same faces as Enkeon's Console, so the page reads the same.
const inter = Inter({ subsets: ["latin"], display: "swap", variable: "--font-inter" });
const plusJakartaSans = Plus_Jakarta_Sans({ subsets: ["latin"], display: "swap", variable: "--font-heading" });

export const metadata: Metadata = { title: "Cookie" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${plusJakartaSans.variable}`}>
      <body>{children}</body>
    </html>
  );
}
