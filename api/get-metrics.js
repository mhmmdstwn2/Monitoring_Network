import fs from 'fs';
import path from 'path';

export default function handler(req, res) {
    const token = req.headers.authorization;
    
    // Cek apakah ada token (user sudah login)
    if (!token || token === 'null') {
        return res.status(403).json({ error: "Unauthorized access" });
    }

    try {
        const filePath = path.join(process.cwd(), 'data', 'metrics.json');
        const fileData = fs.readFileSync(filePath, 'utf8');
        res.status(200).json(JSON.parse(fileData));
    } catch (err) {
        res.status(500).json({ error: "Data metrics tidak ditemukan" });
    }
}
