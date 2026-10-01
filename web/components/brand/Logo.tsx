/** The horizontal lockup: the Fixed lens mark and the outlined Inter Display wordmark. */
export function Lockup({ className = "h-9 w-auto" }: { className?: string }) {
  return <img src="/synced/brand/logo/redlamp-lockup.svg" alt="Redlamp" className={className} />;
}

export function Mark({ className = "size-7" }: { className?: string }) {
  return <img src="/synced/brand/logo/redlamp-mark.svg" alt="" className={className} />;
}

export function AppIcon({ size = 64, className = "" }: { size?: number; className?: string }) {
  return (
    <img
      src="/synced/brand/images/app-icon.png"
      alt="The Redlamp app icon: a glowing ruby safelight lens in a steel bezel"
      width={size}
      height={size}
      className={className}
    />
  );
}
