import { Database } from "./database";

export interface User {
  id: string;
  email: string;
  createdAt: Date;
}

export class UserService {
  constructor(private readonly db: Database) {}

  async findById(id: string): Promise<User | null> {
    const row = await this.db.queryOne("SELECT * FROM users WHERE id = $1", [id]);
    return row ? this.toUser(row) : null;
  }

  async create(email: string): Promise<User> {
    const row = await this.db.queryOne(
      "INSERT INTO users (email) VALUES ($1) RETURNING *",
      [email],
    );
    return this.toUser(row);
  }

  private toUser(row: Record<string, unknown>): User {
    return {
      id: String(row.id),
      email: String(row.email),
      createdAt: new Date(String(row.created_at)),
    };
  }
}
