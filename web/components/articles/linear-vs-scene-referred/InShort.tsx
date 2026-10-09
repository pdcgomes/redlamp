const points = [
  { title: "Linear", text: "How the numbers are written: twice the light, twice the number." },
  {
    title: "Scene-referred",
    text: "Whose light they describe: the light in front of the camera, which has no ceiling, rather than the light a screen gives off, which stops at white.",
  },
  {
    title: "The tone curve",
    text: "What turns scene light into screen light. A scene-referred mode, which the feedback asks for, would leave it out, without changing how files are encoded.",
  },
];

export function InShort() {
  return (
    <div className="mx-auto grid max-w-3xl gap-x-8 gap-y-6 border-y border-hairline py-8 sm:grid-cols-3">
      {points.map((point) => (
        <div key={point.title}>
          <p className="font-display text-[18px] text-paper">{point.title}</p>
          <p className="mt-2 text-[15px] leading-relaxed text-mute">{point.text}</p>
        </div>
      ))}
    </div>
  );
}
