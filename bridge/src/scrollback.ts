export class ScrollbackBuffer {
  private chunks: string[] = [];
  private totalLength = 0;
  private maxLength: number;

  constructor(maxLength = 10_000) {
    this.maxLength = maxLength;
  }

  append(data: string): void {
    this.chunks.push(data);
    this.totalLength += data.length;

    if (this.totalLength > this.maxLength) {
      this.compact();
    }
  }

  getContents(): string {
    this.compact();
    return this.chunks.join("");
  }

  clear(): void {
    this.chunks = [];
    this.totalLength = 0;
  }

  private compact(): void {
    const joined = this.chunks.join("");
    if (joined.length > this.maxLength) {
      this.chunks = [joined.slice(joined.length - this.maxLength)];
      this.totalLength = this.chunks[0].length;
    } else {
      this.chunks = [joined];
      this.totalLength = joined.length;
    }
  }
}
