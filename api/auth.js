// Backend Logic - Node.js
const fs = require('fs');
const path = require('path');

export default function handler(req, res) {
    const { action, email, password, apiKey } = req.body;
    const dbPath = path.join(process.cwd(), 'data', 'users.json');
    let users = JSON.parse(fs.readFileSync(dbPath, 'utf8'));

    if (action === 'signup') {
        if (users.find(u => u.email === email)) return res.status(400).json({ error: 'User exists' });
        const newUser = { email, password, token: btoa(email + Date.now()) }; // Token sederhana
        users.push(newUser);
        fs.writeFileSync(dbPath, JSON.stringify(users));
        return res.json({ success: true, token: newUser.token });
    }

    if (action === 'login') {
        const user = users.find(u => u.email === email && u.password === password);
        if (user) return res.json({ success: true, token: user.token });
        return res.status(401).json({ error: 'Invalid credentials' });
    }
}