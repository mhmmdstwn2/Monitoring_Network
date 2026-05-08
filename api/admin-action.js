import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_URI;
const client = new MongoClient(uri);

export default async function handler(req, res) {
    // Keamanan: Cek apakah yang akses punya token admin? (Opsional tapi bagus)
    
    try {
        await client.connect();
        const db = client.db('netmon_db');
        const users = db.collection('users');

        if (req.method === 'GET') {
            const allUsers = await users.find({}).toArray();
            return res.json(allUsers);
        }

        if (req.method === 'POST') {
            const { action, username } = JSON.parse(req.body);
            if (action === 'delete') {
                await users.deleteOne({ username });
                return res.json({ success: true });
            }
        }
    } catch (e) {
        res.status(500).json({ error: e.message });
    } finally { await client.close(); }
}
