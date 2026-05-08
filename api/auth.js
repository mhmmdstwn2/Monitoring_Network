import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_URI;
const client = new MongoClient(uri);

export default async function handler(req, res) {
    if (req.method !== 'POST') return res.status(405).json({ message: 'Method not allowed' });
    
    const { action, email, password } = req.body;

    try {
        await client.connect();
        const db = client.db('netmon_db');
        const users = db.collection('users');

        if (action === 'signup') {
            const userExists = await users.findOne({ email });
            if (userExists) return res.status(400).json({ success: false, message: 'Email sudah terdaftar' });
            
            const result = await users.insertOne({ email, password, createdAt: new Date() });
            return res.json({ success: true, message: 'Berhasil daftar, silakan login' });
        }

        if (action === 'login') {
            const user = await users.findOne({ email, password });
            if (!user) return res.status(401).json({ success: false, message: 'Email atau Password salah' });
            
            // Token sederhana untuk session
            const token = btoa(user.email + ":" + user._id);
            return res.json({ success: true, token });
        }
    } catch (error) {
        return res.status(500).json({ success: false, message: error.message });
    } finally {
        await client.close();
    }
}
