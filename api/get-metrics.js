import fs from 'fs';
import path from 'path');

export default function handler(req, res) {
    const token = req.headers.authorization;
    if (!token) return res.status(403).json({ error: "No Token" });

    try {
        const filePath = path.join(process.cwd(), 'data', 'metrics.json');
        const fileData = fs.readFileSync(filePath, 'utf8');
        res.status(200).json(JSON.parse(fileData));
    } catch (err) {
        res.status(500).json({ error: "Data not found" });
    }
}