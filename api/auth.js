import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_URI;
const client = new MongoClient(uri);

export default async function handler(req, res) {
    // Hanya izinkan method POST
    if (req.method !== 'POST') {
        return res.status(405).json({ success: false, message: 'Method not allowed' });
    }

    const { action, username, password, role } = req.body;

    try {
        await client.connect();
        const db = client.db('netmon_db');
        const users = db.collection('users');

        // --- LOGIC LOGIN ---
        if (action === 'login') {
            const user = await users.findOne({ username, password });
            
            if (!user) {
                return res.status(401).json({ 
                    success: false, 
                    message: 'Username atau Password salah!' 
                });
            }

            // Kirim token dan role agar frontend tahu harus redirect ke mana
            return res.json({ 
                success: true, 
                token: "SESSION-" + btoa(user.username + ":" + Date.now()),
                role: user.role || "user" 
            });
        }

        // --- LOGIC SIGNUP (Dipanggil dari Admin Dashboard) ---
        if (action === 'signup') {
            // Cek apakah username sudah dipakai
            const userExists = await users.findOne({ username });
            if (userExists) {
                return res.status(400).json({ 
                    success: false, 
                    message: 'Username ini sudah terdaftar!' 
                });
            }

            // Simpan user baru ke database
            await users.insertOne({ 
                username, 
                password, 
                role: role || "user", // Jika admin tidak pilih role, default-nya 'user'
                createdAt: new Date() 
            });

            return res.json({ 
                success: true, 
                message: 'Akun berhasil dibuat!' 
            });
        }

        return res.status(400).json({ success: false, message: 'Action tidak valid' });

    } catch (error) {
        console.error("Database Error:", error);
        return res.status(500).json({ 
            success: false, 
            message: "Gagal terhubung ke database: " + error.message 
        });
    } finally {
        // Jangan lupa tutup koneksi setiap selesai
        await client.close();
    }
}
