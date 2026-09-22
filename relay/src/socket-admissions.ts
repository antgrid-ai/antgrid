export type AdmissionRejection = "global" | "ip";

export class SocketAdmissions {
  private readonly reservations = new Map<string, string>();
  private readonly byIp = new Map<string, number>();

  constructor(
    private readonly globalLimit: number,
    private readonly perIpLimit: number,
  ) {}

  reserve(id: string, ip: string): AdmissionRejection | undefined {
    if (this.reservations.has(id)) throw new Error(`duplicate socket reservation: ${id}`);
    if ((this.byIp.get(ip) ?? 0) >= this.perIpLimit) return "ip";
    if (this.reservations.size >= this.globalLimit) return "global";
    this.reservations.set(id, ip);
    this.byIp.set(ip, (this.byIp.get(ip) ?? 0) + 1);
    return undefined;
  }

  release(id: string): boolean {
    const ip = this.reservations.get(id);
    if (ip === undefined) return false;
    this.reservations.delete(id);
    const count = this.byIp.get(ip) ?? 0;
    if (count <= 1) this.byIp.delete(ip);
    else this.byIp.set(ip, count - 1);
    return true;
  }

  get size(): number {
    return this.reservations.size;
  }

  countForIp(ip: string): number {
    return this.byIp.get(ip) ?? 0;
  }

  clear(): void {
    this.reservations.clear();
    this.byIp.clear();
  }
}
