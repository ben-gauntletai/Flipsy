import { getFirestore } from "firebase-admin/firestore";

export const getDb = () => {
    return getFirestore();
}; 