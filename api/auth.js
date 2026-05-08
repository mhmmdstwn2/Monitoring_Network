import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_URI;
const client = new MongoClient(uri);

export default async function handler(req, res) {
    if (req.method !== 'POST') return res.status(405).json({ message: 'Method not allowed' });
    const { action, username, password } = req.body;

    try {
        await client.connect();
        const db = client.db('netmon_db');
        const users = db.collection('users');

        if (action === 'login') {
            const user = await users.findOne({ username, password });
            if (!user) return res.status(401).json({ success: false, message: 'Invalid Credentials' });
            
            // Kirim token dan role ke frontend
            return res.json({ 
                success: true, 
                token: "SESSION-" + btoa(username),
                role: user.role || "user" // Defaultnya user biasa
            });
        }
        
        // Logic signup tetap sama seperti sebelumnya...
        if (action === 'signup') {
            const exists = await users.findOne({ username });
            if (exists) return res.status(400).json({ success: false, message: 'User exists' });
            await users.insertOne({ username, password, role: "user", createdAt: new Date() });
            return res.json({ success: true });
        }
    } catch (e) {
        return res.status(500).json({ message: e.message });
    } finally { await client.close(); }
}
