export const blogImageOptions = {
  quality: 80,
  widths: [480, 768, 1088, 1600, 2176],
  sizes: "(min-width: 71rem) 68rem, calc(100vw - 3rem)",
};

/** @param {string} sourceFormat */
export function getBlogImageOptions(sourceFormat) {
  // Vectors need neither rasterization nor multiple resolution variants.
  return sourceFormat.toLowerCase() === "svg"
    ? { format: /** @type {const} */ ("svg") }
    : { ...blogImageOptions, format: /** @type {const} */ ("webp") };
}
